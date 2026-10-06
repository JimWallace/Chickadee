// Worker/JobCgroups.swift
//
// A cgroup for each sandboxed command (#2252). Every job on a runner shares the
// container's memory, so before this one job that allocated without bound used
// the memory of every job beside it, and the kernel's OOM killer then chose a
// process anywhere in the container: another job, or the runner. A job's
// private tmpfs (`--job-disk-limit`) bounded the files it holds, not its
// processes.
//
// The runner container's pre-step (deploy/runner-entrypoint.sh) moves the
// runner into `/sandbox/runner` and gives it `/sandbox/jobs`, with the memory
// and pids controllers enabled. For each sandboxed command, the runner creates
// a child of `/sandbox/jobs` with `memory.max` at `--job-memory-limit`, no swap,
// and `pids.max` at the command's process limit. The sandbox prelude moves
// itself into that cgroup before it starts the command, so the command and
// every process it starts are in it. The kernel then stops a job that uses too
// much memory, and only that job. When the command ends, the runner kills what
// is left in the cgroup (`cgroup.kill`), so a process that the command left in
// the background does not outlive it, and removes the cgroup.
//
// Nothing is configured: the runner finds `/sandbox/jobs` from its own cgroup
// in `/proc/self/cgroup`. A runner that did not start through the pre-step, or
// a host without cgroup v2, has no job cgroups; the runner says why at startup
// and grades without them.

import Foundation

/// The delegated cgroup that holds a cgroup per sandboxed command.
struct JobCgroups: Sendable, Equatable {

    /// The default for `--job-memory-limit`, in megabytes. A JVM, `g++` on a
    /// large translation unit, or pandas on a course dataset each fit, with the
    /// job's private tmpfs (`--job-disk-limit`), whose pages count here too.
    static let defaultMemoryLimitMegabytes = 1024

    /// Where cgroup v2 is mounted.
    static let mountPoint = URL(fileURLWithPath: "/sys/fs/cgroup", isDirectory: true)

    /// The directory under which each command gets its cgroup.
    let jobsDirectory: URL

    /// What `discover` found.
    enum Discovery: Equatable {
        case available(JobCgroups)
        case unavailable(reason: String)
    }

    /// Finds the delegated `jobs` cgroup beside the runner's own.
    ///
    /// - Parameters:
    ///   - selfCgroup: the contents of `/proc/self/cgroup`, or `nil` when it
    ///     cannot be read.
    ///   - mountPoint: where cgroup v2 is mounted.
    static func discover(selfCgroup: String?, mountPoint: URL = mountPoint) -> Discovery {
        guard let selfCgroup else {
            return .unavailable(reason: "cannot read /proc/self/cgroup")
        }
        // cgroup v2 has one line, "0::<path>". A host on cgroup v1 has none.
        guard
            let path = selfCgroup.split(separator: "\n").first(where: { $0.hasPrefix("0::") })
                .map({ String($0.dropFirst(3)) })
        else {
            return .unavailable(reason: "the host does not use cgroup v2")
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.last == "runner" else {
            return .unavailable(
                reason: "the runner runs in the cgroup \(path), not in the runner cgroup that "
                    + "runner-entrypoint.sh creates")
        }
        let jobsDirectory = components.dropLast().reduce(mountPoint) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.appendingPathComponent("jobs", isDirectory: true)

        guard
            let controllers = try? String(
                contentsOf: jobsDirectory.appendingPathComponent("cgroup.subtree_control"), encoding: .utf8)
        else {
            return .unavailable(reason: "\(jobsDirectory.path) does not exist")
        }
        let enabled = Set(controllers.split(whereSeparator: \.isWhitespace).map(String.init))
        guard enabled.isSuperset(of: ["memory", "pids"]) else {
            return .unavailable(reason: "memory and pids are not enabled in \(jobsDirectory.path)")
        }
        guard access(jobsDirectory.path, W_OK) == 0 else {
            return .unavailable(reason: "the runner cannot write to \(jobsDirectory.path)")
        }
        return .available(JobCgroups(jobsDirectory: jobsDirectory))
    }

    /// `discover(selfCgroup:)` for this process.
    static func discover() -> Discovery {
        discover(selfCgroup: try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8))
    }

    /// Creates a cgroup for one command, with its limits set.
    ///
    /// `pids.max` is the command's own process plus `processLimit`, which is
    /// what `--job-process-limit` promises. Unlike `RLIMIT_NPROC`, the kernel
    /// applies it when the runner runs as root too.
    func makeJobCgroup(memoryLimitMegabytes: Int, processLimit: Int) throws(JobCgroupError) -> JobCgroup {
        let directory = jobsDirectory.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(directory.path, 0o755) == 0 else {
            throw .cannotCreate(directory.path, errno: errno)
        }
        let cgroup = JobCgroup(directory: directory)
        do {
            try cgroup.write(String(memoryLimitMegabytes * 1024 * 1024), to: "memory.max")
            // Swap would let a job past its limit instead of stopping it. The
            // file exists only when the kernel accounts swap.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.swap.max").path) {
                try cgroup.write("0", to: "memory.swap.max")
            }
            try cgroup.write(String(processLimit + 1), to: "pids.max")
        } catch {
            rmdir(directory.path)
            throw error
        }
        return cgroup
    }
}
