// Worker/SandboxedScriptRunner.swift
//
// Phase 4: sandboxed subprocess execution.
//
// On Linux  — uses `unshare --user --net --mount --map-root-user` to run the
//             script inside a private user namespace (no real privileges), a
//             private network namespace (no outbound connectivity) and a
//             private mount namespace, in which the work root is covered by
//             an empty tmpfs and only the job's own directories are bound
//             back into place (#2061), and /tmp, /dev/shm, /var/tmp and
//             HOME are fresh, empty and private to the job. A script may start
//             at most `processLimit` processes and threads at once (#2224).
//             Everything a test script writes, in those places and in its
//             working directory, goes to one private tmpfs of
//             `diskLimitMegabytes` that is discarded when it ends (#2251,
//             #2252).
//
// On macOS  — uses `sandbox-exec -p <profile>` to enforce a TCC-level policy:
//             deny all network, allow file-reads from the system prefix except
//             the work root, allow file-reads and file-writes only inside the
//             job's own directories.
//
// Callers interact through the ScriptRunner protocol; no change is needed at
// call sites compared to UnsandboxedScriptRunner. The sandbox is entirely a
// matter of which executable leads the argument vector — the launch, capture,
// and time-limit machinery is the shared one in ScriptExecution.swift.
//
// WHAT A SCRIPT SEES (#2061). Every job on a runner runs as the runner's user,
// and every job directory is a direct child of one work root: the scratch copy
// of the test setup, which is the script's working directory, and the job
// workspace, which holds the submission and any opponent. With `--max-jobs`
// above 1, a script could read the workspace of a job running beside it,
// which holds another student's submission. So the sandbox hides every
// sibling of the working directory: the parent directory (the work root) is
// covered, and only the working directory and each directory the script's
// environment names (`CHICKADEE_OPPONENT_DIR`) are visible under it. Nothing
// is configured: the work root is derived from the working directory, because
// the runner creates both.

import Core
import Foundation

struct SandboxedScriptRunner: ScriptRunner {

    /// The default for `--job-process-limit`. A JVM needs about 20 to 70
    /// threads, depending on the host's CPU count, and `javac` or `g++` a few
    /// processes more.
    static let defaultProcessLimit = 128

    /// The most processes and threads a script may start, counted together and
    /// at once, its children's included (#2224). Every job runs as the runner's user, so without a
    /// limit of its own one job could fork until the container's `pids_limit`
    /// is used up, and the jobs beside it could no longer start a process.
    ///
    /// The kernel counts `RLIMIT_NPROC` per user namespace (Linux 5.14 and
    /// later), and each script runs in a user namespace of its own, so the
    /// limit counts only this script's processes, not the other jobs'. The
    /// script cannot raise it: that needs `CAP_SYS_RESOURCE` outside its
    /// namespace. The kernel does not apply the limit when the runner itself
    /// runs as root; `processLimitIsEnforced(workDir:)` detects that.
    let processLimit: Int

    /// The default for `--job-disk-limit`, in megabytes. A `g++` or `javac`
    /// build of a test and its submission needs a few megabytes.
    static let defaultDiskLimitMegabytes = 256

    /// How much a script may write in all, in megabytes: in its working
    /// directory, `/tmp`, `/var/tmp`, `/dev/shm` and `HOME` together, in one
    /// private tmpfs (#2251, #2252). A tmpfs is memory that belongs to no
    /// process, so this also bounds the memory a job holds outside its
    /// processes. The job directories live on one mount that every job
    /// on the runner shares, so one script that wrote without bound filled it,
    /// and every other job then failed to write. Now the script's writes go to
    /// a private, size-limited space over the working directory (an overlay),
    /// and they are discarded when the script ends: a full space fails only
    /// that script. No test reads a file that an earlier test wrote, and the
    /// runner reads only a script's output, so nothing depends on the writes.
    /// The make step keeps its writes, because the tests use what it builds.
    let diskLimitMegabytes: Int

    /// How much memory one command may use, in megabytes: its processes and
    /// its private tmpfs together (#2252). It applies only when `cgroups` is
    /// set.
    let memoryLimitMegabytes: Int

    /// The delegated cgroup that holds a cgroup per command, or `nil` when the
    /// host has none. Without it, a command's memory is not limited.
    let cgroups: JobCgroups?

    init(
        processLimit: Int = Self.defaultProcessLimit,
        diskLimitMegabytes: Int = Self.defaultDiskLimitMegabytes,
        memoryLimitMegabytes: Int = JobCgroups.defaultMemoryLimitMegabytes,
        cgroups: JobCgroups? = nil
    ) {
        self.processLimit = processLimit
        self.diskLimitMegabytes = diskLimitMegabytes
        self.memoryLimitMegabytes = memoryLimitMegabytes
        self.cgroups = cgroups
    }

    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
        await run(script: script, workDir: workDir, timeLimitSeconds: timeLimitSeconds, env: env, hiding: [])
    }

    func run(
        script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String], hiding hiddenFiles: [URL]
    ) async -> ScriptOutput {
        await inJobCgroup { cgroup in
            await executeScriptLaunch(
                sandboxedLaunch(
                    script: script, workDir: workDir, env: env, hiding: hiddenFiles,
                    limits: SandboxLimits(
                        processes: processLimit, diskMegabytes: diskLimitMegabytes,
                        keepsWorkingDirectoryWrites: false, cgroup: cgroup?.directory)),
                workDir: workDir,
                timeLimitSeconds: timeLimitSeconds,
                launchErrorPrefix: "Failed to launch sandboxed script"
            )
        }
    }

    func run(
        command executablePath: String, arguments: [String], workDir: URL, timeLimitSeconds: Int,
        launchErrorPrefix: String
    ) async -> ScriptOutput {
        await inJobCgroup { cgroup in
            await executeScriptLaunch(
                sandboxWrap(
                    executablePath: executablePath,
                    arguments: arguments,
                    workDir: workDir,
                    environment: mergedScriptEnvironment(overrides: [:]),
                    limits: SandboxLimits(
                        processes: processLimit, diskMegabytes: diskLimitMegabytes,
                        keepsWorkingDirectoryWrites: true, cgroup: cgroup?.directory)),
                workDir: workDir,
                timeLimitSeconds: timeLimitSeconds,
                launchErrorPrefix: launchErrorPrefix
            )
        }
    }

    /// Runs `body` with a fresh cgroup for its command, then removes the
    /// cgroup and every process left in it. When the kernel stopped the command
    /// for want of memory, the output says so, and says whether the command
    /// reached its own limit or the container ran out, because otherwise the
    /// student sees only an exit code of 137.
    ///
    /// When the cgroup cannot be created, the command runs without one and the
    /// runner logs why: a job is graded rather than failed for a fault of the
    /// runner's.
    private func inJobCgroup(_ body: (JobCgroup?) async -> ScriptOutput) async -> ScriptOutput {
        guard let cgroups else { return await body(nil) }
        let cgroup: JobCgroup
        do {
            cgroup = try cgroups.makeJobCgroup(
                memoryLimitMegabytes: memoryLimitMegabytes, processLimit: processLimit)
        } catch {
            writeStructuredRunnerLog(
                event: "job_cgroup_unavailable", fields: ["error": error.description])
            return await body(nil)
        }
        let output = await body(cgroup)
        let events = cgroup.memoryEvents
        await cgroup.remove()
        guard let note = Self.memoryStopMessage(memoryEvents: events, megabytes: memoryLimitMegabytes)
        else { return output }
        return ScriptOutput(
            exitCode: output.exitCode,
            stdout: output.stdout,
            stderr: output.stderr + note,
            executionTimeMs: output.executionTimeMs,
            timedOut: output.timedOut)
    }

    /// The line added to a command's stderr when the kernel stopped a process
    /// of it for want of memory, or `nil` when it did not. A command that did
    /// not reach its own limit was stopped because the container ran out,
    /// which is not the test's fault, and the message must not say otherwise.
    static func memoryStopMessage(memoryEvents events: String, megabytes: Int) -> String? {
        guard JobCgroup.oomKills(inMemoryEvents: events) > 0 else { return nil }
        return JobCgroup.ownLimitOOMs(inMemoryEvents: events) > 0
            ? memoryLimitMessage(megabytes: megabytes)
            : runnerOutOfMemoryMessage(megabytes: megabytes)
    }

    /// The line for a command that the kernel stopped because the container,
    /// not the command, ran out of memory.
    static func runnerOutOfMemoryMessage(megabytes: Int) -> String {
        "\nsandbox: the runner ran out of memory and stopped the test, which had not reached "
            + "its own memory limit of \(megabytes) MB\n"
    }

    /// The line added to a command's stderr when the kernel stopped it at its
    /// memory limit.
    static func memoryLimitMessage(megabytes: Int) -> String {
        "\nsandbox: the test used more than its memory limit of \(megabytes) MB and was stopped\n"
    }
}

// MARK: - Startup probe

extension SandboxedScriptRunner {

    /// What an operator can do when the probe fails. It depends on the platform,
    /// because each sandbox is refused for a different reason.
    static var probeFailureAdvice: String {
        #if os(Linux)
        return "A container that drops capabilities or uses the default seccomp profile "
            + "refuses user and mount namespaces. Remove --sandbox, or allow them."
        #elseif os(macOS)
        return "sandbox-exec cannot start inside another sandbox. "
            + "Remove --sandbox, or start the runner outside the sandbox."
        #else
        return "This platform has no sandbox. Remove --sandbox."
        #endif
    }

    /// Checks that this host can start the sandbox, by running a command
    /// inside the same wrapper a real job uses.
    ///
    /// The probe runs in a fresh child directory of `workDir`, as a job runs
    /// in a child of the work root, beside a marker file that stands in for
    /// another job. The command passes only when the marker is hidden and the
    /// working directory is writable, so a host that starts the namespaces
    /// but refuses the mounts inside them is reported too. It runs with the
    /// working-directory overlay a test script gets, so a kernel that cannot
    /// mount an overlay in a user namespace (before Linux 5.11) is reported
    /// as well.
    ///
    /// Returns `nil` when the sandbox works. Otherwise it returns the reason,
    /// for the operator. A container that drops capabilities or uses the
    /// default seccomp profile refuses `unshare`. Without this check, every
    /// job would fail on that refusal. The failure would look like a broken
    /// test script, not a broken runner.
    static func probe(workDir: URL) async -> String? {
        let fileManager = FileManager.default
        let probeDir = workDir.appendingPathComponent(
            "chickadee-sandbox-probe-\(UUID().uuidString)", isDirectory: true)
        let marker = workDir.appendingPathComponent("chickadee-sandbox-probe-\(UUID().uuidString).marker")
        do {
            try fileManager.createDirectory(at: probeDir, withIntermediateDirectories: false)
            try Data().write(to: marker)
        } catch {
            try? fileManager.removeItem(at: probeDir)
            try? fileManager.removeItem(at: marker)
            return "cannot write to the work root \(workDir.path): \(error.localizedDescription)"
        }
        defer {
            try? fileManager.removeItem(at: probeDir)
            try? fileManager.removeItem(at: marker)
        }
        let output = await executeScriptLaunch(
            sandboxWrap(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "if [ -e \"$1\" ]; then echo \"the sandbox did not hide $1\" >&2; exit 1; fi; "
                        + "if [ ! -w . ]; then echo \"the working directory is not writable\" >&2; exit 1; fi",
                    "probe", marker.path,
                ],
                workDir: probeDir,
                environment: mergedScriptEnvironment(overrides: [:]),
                limits: SandboxLimits(
                    processes: defaultProcessLimit, diskMegabytes: defaultDiskLimitMegabytes,
                    keepsWorkingDirectoryWrites: false, cgroup: nil)),
            workDir: probeDir,
            timeLimitSeconds: 10,
            launchErrorPrefix: "Failed to launch sandbox probe")
        guard output.exitCode != 0 else { return nil }
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "probe exited with code \(output.exitCode)" : detail
    }

    /// Checks that the kernel applies `processLimit` to a sandboxed script.
    ///
    /// It starts a sandbox that may hold no process beyond its own and asks it
    /// to fork once. The fork must be refused. The kernel does not apply
    /// `RLIMIT_NPROC` when the runner runs as root, so on such a runner one job
    /// can still fork until the container's `pids_limit` is used up. The
    /// sandbox works otherwise, so the runner warns rather than refuses.
    ///
    /// Always `true` on a platform with no process limit to check: there is
    /// nothing to warn about that the platform's sandbox could change.
    static func processLimitIsEnforced(workDir: URL) async -> Bool {
        #if os(Linux)
        let probeDir = workDir.appendingPathComponent(
            "chickadee-sandbox-probe-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: false)) != nil
        else { return false }
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let output = await executeScriptLaunch(
            sandboxWrap(
                executablePath: "/bin/sh",
                arguments: ["-c", "( : )"],
                workDir: probeDir,
                environment: mergedScriptEnvironment(overrides: [:]),
                limits: SandboxLimits(
                    processes: 0, diskMegabytes: defaultDiskLimitMegabytes,
                    keepsWorkingDirectoryWrites: true, cgroup: nil)),
            workDir: probeDir,
            timeLimitSeconds: 10,
            launchErrorPrefix: "Failed to launch sandbox process-limit probe")
        return output.exitCode != 0 && !output.timedOut
        #else
        return true
        #endif
    }
}

// MARK: - Job cgroup probe

extension SandboxedScriptRunner {

    /// Checks that a sandboxed command runs in its own cgroup, under its
    /// memory limit, and cannot change that limit (#2252).
    ///
    /// It runs one command through the same wrapper and the same cgroup steps
    /// as a real job. The command must report the job's cgroup as its own,
    /// read the job's `memory.max` at `/sys/fs/cgroup`, and fail to write it.
    ///
    /// Returns `nil` when the job cgroups work. Otherwise it returns the
    /// reason, and the runner grades without them.
    static func jobCgroupProbe(cgroups: JobCgroups, workDir: URL) async -> String? {
        #if os(Linux)
        let probeDir = workDir.appendingPathComponent(
            "chickadee-sandbox-probe-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: false)) != nil
        else { return "cannot write to the work root \(workDir.path)" }
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let megabytes = 64
        let cgroup: JobCgroup
        do {
            cgroup = try cgroups.makeJobCgroup(memoryLimitMegabytes: megabytes, processLimit: defaultProcessLimit)
        } catch {
            return error.description
        }
        let output = await executeScriptLaunch(
            sandboxWrap(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "cat /proc/self/cgroup; cat /sys/fs/cgroup/memory.max; "
                        + "if { echo max > /sys/fs/cgroup/memory.max; } 2>/dev/null; then echo writable; fi",
                ],
                workDir: probeDir,
                environment: mergedScriptEnvironment(overrides: [:]),
                limits: SandboxLimits(
                    processes: defaultProcessLimit, diskMegabytes: defaultDiskLimitMegabytes,
                    keepsWorkingDirectoryWrites: false, cgroup: cgroup.directory)),
            workDir: probeDir,
            timeLimitSeconds: 10,
            launchErrorPrefix: "Failed to launch job cgroup probe")
        await cgroup.remove()
        return jobCgroupProbeFailure(
            output: output, jobCgroupName: cgroup.directory.lastPathComponent,
            memoryLimitBytes: megabytes * 1024 * 1024)
        #else
        return "job cgroups need Linux"
        #endif
    }

    /// Reads the probe's output: its cgroup, the limit it read, and whether it
    /// could write that limit. Returns `nil` when all three are as expected.
    static func jobCgroupProbeFailure(
        output: ScriptOutput, jobCgroupName: String, memoryLimitBytes: Int
    )
        -> String?
    {
        guard output.exitCode == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "the probe exited with code \(output.exitCode)" : detail
        }
        let lines = output.stdout.split(separator: "\n").map(String.init)
        guard let cgroupLine = lines.first, cgroupLine.hasPrefix("0::"), cgroupLine.hasSuffix("/\(jobCgroupName)")
        else {
            return "the command did not run in its job cgroup: \(lines.first ?? "no output")"
        }
        guard lines.count > 1, lines[1] == String(memoryLimitBytes) else {
            return "the command did not see its memory limit at /sys/fs/cgroup/memory.max"
        }
        guard !lines.contains("writable") else {
            return "the command could change its own memory limit"
        }
        return nil
    }
}

// MARK: - Platform-specific sandbox setup

private func sandboxedLaunch(
    script: URL, workDir: URL, env: [String: String], hiding hiddenFiles: [URL], limits: SandboxLimits
)
    -> ScriptLaunch
{
    let invocation = scriptInvocation(for: script)
    return sandboxWrap(
        executablePath: invocation.executableURL.path,
        arguments: invocation.arguments,
        workDir: workDir,
        environment: mergedScriptEnvironment(overrides: env),
        hiding: hiddenFiles,
        limits: limits)
}

/// The directories a script may see under the work root: its working
/// directory, and every directory its environment names there. Each job
/// directory is a direct child of the work root, so the root is the parent of
/// the working directory.
struct SandboxVisibleDirectories {
    let workRoot: URL
    let directories: [URL]

    init(workDir: URL, environment: [String: String]) {
        let workDir = workDir.standardizedFileURL
        let root = workDir.deletingLastPathComponent()
        var directories = [workDir]
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for value in environment.values.sorted() {
            guard value.hasPrefix(rootPrefix) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
            if !directories.contains(url) { directories.append(url) }
        }
        self.workRoot = root
        self.directories = directories
    }
}

/// What one sandboxed command may use: processes and threads, and megabytes
/// of private space. `keepsWorkingDirectoryWrites` is `true` for a command
/// whose writes in the working directory the job keeps: the make step.
/// `cgroup` is the command's own cgroup, which holds its memory limit, or
/// `nil` when it has none.
struct SandboxLimits {
    let processes: Int
    let diskMegabytes: Int
    let keepsWorkingDirectoryWrites: Bool
    let cgroup: URL?
}

/// The processes a Linux sandbox holds before its command starts any: the
/// `unshare` parent and the command itself. `RLIMIT_NPROC` counts both, so the
/// prelude adds them to the script's own limit.
let sandboxOwnProcessCount = 2

/// Puts the platform's sandbox launcher in front of a command. The one place
/// that decides how a command is sandboxed, so the probe and real jobs cannot
/// use different wrappers.
private func sandboxWrap(
    executablePath: String,
    arguments commandArguments: [String],
    workDir: URL,
    environment: [String: String],
    hiding hiddenFiles: [URL] = [],
    limits: SandboxLimits
) -> ScriptLaunch {
    let visible = SandboxVisibleDirectories(workDir: workDir, environment: environment)

    #if os(Linux)
    // `sh -c` runs the mount prelude as "root" of the new user namespace; the
    // prelude ends with `exec` of the real command, so the script keeps the
    // process the time limit kills.
    return ScriptLaunch(
        executablePath: "/usr/bin/unshare",
        arguments: [
            "--fork",
            "--kill-child",
            "--user",
            "--net",
            "--mount",
            "--map-root-user",
            "/bin/sh",
            "-c",
            linuxMountPrelude,
            "chickadee-sandbox",
            String(limits.processes + sandboxOwnProcessCount),
            String(limits.diskMegabytes),
            limits.keepsWorkingDirectoryWrites ? "0" : "1",
            limits.cgroup?.path ?? "-",
            visible.workRoot.path,
            String(visible.directories.count),
        ] + visible.directories.map(\.path)
            + [String(hiddenFiles.count)] + hiddenFiles.map(\.standardizedFileURL.path)
            + [executablePath] + commandArguments,
        env: environment
    )
    #elseif os(macOS)
    return ScriptLaunch(
        executablePath: "/usr/bin/sandbox-exec",
        arguments: ["-p", macOSSandboxProfile(visible: visible, hiding: hiddenFiles), executablePath]
            + commandArguments,
        env: environment
    )
    #else
    // Fallback: unsandboxed (unknown platform). Matches UnsandboxedScriptRunner
    // behaviour so the worker remains functional on unexpected targets.
    return ScriptLaunch(
        executablePath: executablePath,
        arguments: commandArguments,
        env: environment
    )
    #endif
}

// MARK: - Linux mount prelude

#if os(Linux)
/// Runs inside the new namespaces, before the real command. Arguments: the
/// process limit, the size of the private space in megabytes, 1 to cover the
/// working directory with the overlay or 0 to keep its writes, the command's
/// cgroup or `-` for none, the work root,
/// the count of visible directories, the visible directories (the
/// working directory first), the count of hidden files, the hidden files, then
/// the command and its arguments.
///
/// Each visible directory is first bound into a private tmpfs on `/mnt`, so
/// the prelude keeps a handle on it. One private tmpfs of the given size then
/// holds everything the command may write, and `/tmp`, `/dev/shm`, `/var/tmp`
/// and `HOME` are bound to fresh, empty folders in it (#2252). One mount, not
/// one per place, so the memory that a job's files hold, which belongs to no
/// process and which the kernel cannot attribute to the job, is at most that
/// size. Every job runs as the same user, so
/// without this a file one job writes there (a compiler's temporary file, R's
/// session directory, Java's `hsperfdata`) is readable by every other job on
/// the runner, and stays for the next one. `HOME` matters most: Python runs `usercustomize.py` from the user site
/// directory, R reads `~/.Rprofile` and Octave reads `~/.octaverc` at start,
/// so on a host whose root file system is writable, one job could otherwise
/// leave code there that runs inside every later job. The image installs
/// nothing into the home directory, so an empty one loses nothing. The work root, which is usually
/// under `/tmp`, is covered by an empty tmpfs, which hides every job directory,
/// and each visible directory is bound back at its own path. `TMPDIR`, when it
/// pointed into the old `/tmp`, is created again in the new one. The working
/// directory is re-entered through the new mounts, so `pwd` reports the path
/// the runner uses. A working directory directly under `/` has no work root to
/// cover, and the prelude refuses it rather than cover `/`. For a test script,
/// an overlay covers the working directory: the script reads the job's files
/// through it, and what it writes goes to the same private tmpfs, which is
/// discarded when the script ends (#2251). The other visible directories
/// (an opponent) are read-only, and so is the tmpfs that covers the work root,
/// so a script cannot write into `..` either: no write reaches the shared
/// mount or escapes the limit. The
/// overlay's `lowerdir` option cannot hold a comma or a colon, so the prelude
/// refuses such a working directory. The command starts
/// under the process limit, soft and hard, set last so the prelude's own
/// `mount` and `mkdir` do not count against it.
///
/// The command starts with no capabilities (#2268). The prelude runs as root of
/// the new user namespace, which owns the mount namespace, so it holds every
/// capability there, and none of the mounts it makes is locked. A command that
/// kept them could `umount` the covers and read every other job and every
/// cached test setup. `setpriv` empties the inheritable, ambient and bounding
/// sets and sets no-new-privs, so not even running a program as root in the
/// namespace gives a capability back. The command needs none: it only reads
/// and writes its own files.
///
/// With a cgroup (#2252), the prelude moves itself into it first, so the
/// command, every process it starts, and every page of the private tmpfs it
/// writes count against the cgroup's limits. It then binds that cgroup,
/// read-only, over `/sys/fs/cgroup`. A cgroup that the runner created belongs
/// to the runner's user, which is root in this namespace, so without the cover
/// the command could raise its own limits or move itself out. With it, the
/// command still reads its own limit there, as a JVM does to size its heap.
private let linuxMountPrelude = """
    set -e
    limit=$1
    disk=$2
    overlay=$3
    cgroup=$4
    root=$5
    count=$6
    shift 6
    if [ "$cgroup" != - ]; then
        echo $$ > "$cgroup/cgroup.procs"
    fi
    if [ "$root" = / ]; then
        echo "sandbox: the working directory sits directly under /, so there is no work root to isolate" >&2
        exit 2
    fi
    cwd=$(pwd)
    case "$cwd" in
        *,* | *:*)
            if [ "$overlay" = 1 ]; then
                echo "sandbox: the working directory $cwd holds a comma or a colon, which an overlay cannot use" >&2
                exit 2
            fi
            ;;
    esac
    mount --make-rprivate /
    mount -t tmpfs -o nosuid,nodev chickadee-stage /mnt
    i=0
    while [ "$i" -lt "$count" ]; do
        mkdir "/mnt/$i"
        mount --bind "$1" "/mnt/$i"
        printf '%s\\n' "$1" >> /mnt/paths
        shift
        i=$((i+1))
    done
    hidden=$1
    shift
    i=0
    while [ "$i" -lt "$hidden" ]; do
        printf '%s\\n' "$1" >> /mnt/hidden
        shift
        i=$((i+1))
    done
    mkdir /mnt/private
    mount -t tmpfs -o nosuid,nodev,size="${disk}m" chickadee-job-private /mnt/private
    mkdir -m 1777 /mnt/private/tmp /mnt/private/var-tmp /mnt/private/shm
    mkdir /mnt/private/home /mnt/private/upper /mnt/private/work
    mount --bind /mnt/private/tmp /tmp
    if [ -d /dev/shm ]; then
        mount --bind /mnt/private/shm /dev/shm
    fi
    if [ -d /var/tmp ]; then
        mount --bind /mnt/private/var-tmp /var/tmp
    fi
    if [ -n "${HOME:-}" ] && [ "$HOME" != / ] && [ -d "$HOME" ]; then
        mount --bind /mnt/private/home "$HOME"
    fi
    mkdir -p "$root"
    mount -t tmpfs -o nosuid,nodev chickadee-work-root "$root"
    i=0
    while IFS= read -r dir; do
        mkdir -p "$dir"
        mount --bind "/mnt/$i" "$dir"
        if [ "$i" -gt 0 ]; then mount -o remount,bind,ro "$dir"; fi
        i=$((i+1))
    done < /mnt/paths
    if [ "$overlay" = 1 ]; then
        mount -t overlay -o "lowerdir=$cwd,upperdir=/mnt/private/upper,workdir=/mnt/private/work" \
            chickadee-job-writes "$cwd"
    fi
    mount -o remount,ro,nosuid,nodev chickadee-work-root "$root"
    if [ "$cgroup" != - ]; then
        mount --bind "$cgroup" /sys/fs/cgroup
        mount -o remount,bind,ro,nosuid,nodev,noexec /sys/fs/cgroup
    fi
    if [ -f /mnt/hidden ]; then
        while IFS= read -r file; do
            if [ -e "$file" ]; then mount --bind /dev/null "$file"; fi
        done < /mnt/hidden
    fi
    umount -l /mnt
    if [ -n "${TMPDIR:-}" ]; then
        mkdir -p "$TMPDIR" 2>/dev/null || true
    fi
    cd "$cwd"
    exec /usr/bin/setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- \
        /usr/bin/prlimit --nproc="$limit:$limit" -- "$@"
    """
#endif

// MARK: - macOS sandbox profile

#if os(macOS)
private func macOSSandboxProfile(visible: SandboxVisibleDirectories, hiding hiddenFiles: [URL]) -> String {
    // Policy intent:
    //   • Read the entire filesystem (system libs, JDK/Python runtimes, etc.),
    //     except the work root, where only the job's own directories are
    //     readable and writable
    //   • Write only inside those directories and /dev/null
    //   • Deny all network access (remote ip, tcp, udp)
    //   • Allow process execution and forking (needed to run sub-commands)
    //
    // The last matching rule wins, so the work root is denied after the
    // read-everything rule, and each visible directory is allowed after that.
    //
    // Resolve symlinks so that the sandbox path matches what the kernel sees.
    // On macOS, FileManager.temporaryDirectory returns /var/folders/… which is
    // a symlink to /private/var/folders/…; URL.resolvingSymlinksInPath() does
    // not traverse /var → /private/var, so we call POSIX realpath(3) directly.
    func realPath(_ url: URL) -> String {
        url.path.withCString { ptr in
            guard let buf = Darwin.realpath(ptr, nil) else { return url.path }
            defer { free(buf) }
            return String(cString: buf)
        }
    }
    let visibleRules = visible.directories
        .map { "(allow file-read* file-write* (subpath \"\(realPath($0))\"))" }
        .joined(separator: "\n")
    // After the allow rules, so the last match denies the other suite scripts.
    let hiddenRules =
        hiddenFiles
        .map { "(deny file-read* file-write* (literal \"\(realPath($0))\"))" }
        .joined(separator: "\n")
    return """
        (version 1)
        (deny default)
        (allow file-read* (subpath "/"))
        (deny file-read* file-write* (subpath "\(realPath(visible.workRoot))"))
        \(visibleRules)
        \(hiddenRules)
        (allow file-write*
            (literal "/dev/null")
            (literal "/dev/stdout")
            (literal "/dev/stderr"))
        (allow process-exec process-fork)
        (allow signal)
        (allow sysctl-read)
        (allow mach-lookup)
        (deny network* (remote ip))
        """
}
#endif
