// Worker/SandboxedScriptRunner.swift
//
// Phase 4: sandboxed subprocess execution.
//
// On Linux  — uses `unshare --user --net --mount --map-root-user` to run the
//             script inside a private user namespace (no real privileges), a
//             private network namespace (no outbound connectivity) and a
//             private mount namespace, in which the work root is covered by
//             an empty tmpfs and only the job's own directories are bound
//             back into place (#2061).
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

    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
        await executeScriptLaunch(
            sandboxedLaunch(script: script, workDir: workDir, env: env),
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch sandboxed script"
        )
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
    /// but refuses the mounts inside them is reported too.
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
                environment: mergedScriptEnvironment(overrides: [:])),
            workDir: probeDir,
            timeLimitSeconds: 10,
            launchErrorPrefix: "Failed to launch sandbox probe")
        guard output.exitCode != 0 else { return nil }
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "probe exited with code \(output.exitCode)" : detail
    }
}

// MARK: - Platform-specific sandbox setup

private func sandboxedLaunch(script: URL, workDir: URL, env: [String: String]) -> ScriptLaunch {
    let invocation = scriptInvocation(for: script)
    return sandboxWrap(
        executablePath: invocation.executableURL.path,
        arguments: invocation.arguments,
        workDir: workDir,
        environment: mergedScriptEnvironment(overrides: env))
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

/// Puts the platform's sandbox launcher in front of a command. The one place
/// that decides how a command is sandboxed, so the probe and real jobs cannot
/// use different wrappers.
private func sandboxWrap(
    executablePath: String,
    arguments commandArguments: [String],
    workDir: URL,
    environment: [String: String]
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
            visible.workRoot.path,
            String(visible.directories.count),
        ] + visible.directories.map(\.path) + [executablePath] + commandArguments,
        env: environment
    )
    #elseif os(macOS)
    return ScriptLaunch(
        executablePath: "/usr/bin/sandbox-exec",
        arguments: ["-p", macOSSandboxProfile(visible: visible), executablePath]
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
/// work root, the count of visible directories, the visible directories, then
/// the command and its arguments.
///
/// Each visible directory is first bound into a private tmpfs on `/mnt`, so
/// the prelude keeps a handle on it. The work root is then covered by an
/// empty tmpfs, which hides every job directory, and each visible directory
/// is bound back at its own path. The working directory is re-entered through
/// the new mounts, so `pwd` reports the path the runner uses. A working
/// directory directly under `/` has no work root to cover, and the prelude
/// refuses it rather than cover `/`.
private let linuxMountPrelude = """
    set -e
    root=$1
    count=$2
    shift 2
    if [ "$root" = / ]; then
        echo "sandbox: the working directory sits directly under /, so there is no work root to isolate" >&2
        exit 2
    fi
    cwd=$(pwd)
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
    mount -t tmpfs -o nosuid,nodev chickadee-work-root "$root"
    i=0
    while IFS= read -r dir; do
        mkdir -p "$dir"
        mount --bind "/mnt/$i" "$dir"
        i=$((i+1))
    done < /mnt/paths
    umount -l /mnt
    cd "$cwd"
    exec "$@"
    """
#endif

// MARK: - macOS sandbox profile

#if os(macOS)
private func macOSSandboxProfile(visible: SandboxVisibleDirectories) -> String {
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
    return """
        (version 1)
        (deny default)
        (allow file-read* (subpath "/"))
        (deny file-read* file-write* (subpath "\(realPath(visible.workRoot))"))
        \(visibleRules)
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
