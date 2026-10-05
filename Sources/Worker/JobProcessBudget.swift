// Worker/JobProcessBudget.swift
//
// Whether the container's process limit leaves room for every job at its own
// limit (#2224). `--job-process-limit` stops one script from forking without
// bound, but it protects the jobs beside it only when the container can hold
// all of them at once: with `--max-jobs 4`, a limit of 128 per job and a
// container `pids_limit` of 64, one job can still use up the container.

import Foundation

struct JobProcessBudget: Equatable {
    /// Processes and threads kept for the runner itself, and for each sandbox's
    /// own `unshare` and shell: the Swift runtime and the event loops start
    /// about two threads per CPU.
    static let runnerReserve = 64

    /// The container's process limit (`pids.max`).
    let containerLimit: Int
    let maxJobs: Int
    let processLimit: Int

    /// The container limit that lets every job reach its own limit at once.
    var required: Int { maxJobs * processLimit + Self.runnerReserve }

    /// The startup warning when the container limit is too small, else `nil`.
    var warning: String? {
        guard containerLimit < required else { return nil }
        return "Warning: the container allows \(containerLimit) processes, but \(maxJobs) jobs at "
            + "--job-process-limit \(processLimit) and the runner need \(required). One job can then "
            + "use up the container's processes and stop the jobs beside it. Set the container's "
            + "pids_limit to at least \(required), or lower --max-jobs or --job-process-limit.\n"
    }

    /// The cgroup files that hold a container's process limit: cgroup v2 in a
    /// private cgroup namespace (Docker's default), then cgroup v1.
    static let containerLimitPaths = [
        "/sys/fs/cgroup/pids.max",
        "/sys/fs/cgroup/pids/pids.max",
    ]

    /// The container's process limit, or `nil` when there is none (`max`) or
    /// no cgroup file is readable, as outside a container.
    static func readContainerLimit(paths: [String] = containerLimitPaths) -> Int? {
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
