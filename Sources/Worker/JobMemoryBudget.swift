// Worker/JobMemoryBudget.swift
//
// Whether the container's memory limit leaves room for every job at its own
// limit (#2252). `--job-memory-limit` stops one job from using the memory of
// the jobs beside it, but only when the container can hold all of them at
// once. With `--max-jobs 4`, a limit of 1024 MB per job and a container limit
// of 2 GB, several jobs together reach the container limit first, and the
// kernel then stops the largest process in the container, which need not be
// the job that grew.

import Foundation

struct JobMemoryBudget: Equatable {
    /// Megabytes kept for the runner itself and for each sandbox's own
    /// `unshare` and shell.
    static let runnerReserveMegabytes = 512

    /// The container's memory limit (`memory.max`), in bytes.
    let containerLimitBytes: Int
    let maxJobs: Int
    let memoryLimitMegabytes: Int

    /// The container limit, in megabytes, that lets every job reach its own
    /// limit at once.
    var requiredMegabytes: Int { maxJobs * memoryLimitMegabytes + Self.runnerReserveMegabytes }

    /// The largest `--job-memory-limit` that fits this container with
    /// `maxJobs` jobs, or `nil` when not even 1 MB per job fits.
    var fittingJobLimitMegabytes: Int? {
        let perJob = (containerLimitBytes / (1024 * 1024) - Self.runnerReserveMegabytes) / maxJobs
        return perJob >= 1 ? perJob : nil
    }

    /// The startup warning when the container limit is too small, else `nil`.
    var warning: String? {
        let containerMegabytes = containerLimitBytes / (1024 * 1024)
        guard containerMegabytes < requiredMegabytes else { return nil }
        let fits = fittingJobLimitMegabytes.map { " (--job-memory-limit \($0) fits)" } ?? ""
        return "Warning: the container allows \(containerMegabytes) MB of memory, but \(maxJobs) jobs at "
            + "--job-memory-limit \(memoryLimitMegabytes) and the runner need \(requiredMegabytes) MB. "
            + "Several jobs together can then reach the container's limit first, and the kernel stops "
            + "the largest process in the container, which need not be the job that grew. Set the "
            + "container's memory limit to at least \(requiredMegabytes) MB, or lower --max-jobs or "
            + "--job-memory-limit\(fits).\n"
    }

    /// The cgroup files that hold a container's memory limit: cgroup v2 in a
    /// private cgroup namespace (Docker's default), then cgroup v1.
    static let containerLimitPaths = [
        "/sys/fs/cgroup/memory.max",
        "/sys/fs/cgroup/memory/memory.limit_in_bytes",
    ]

    /// The container's memory limit in bytes, or `nil` when there is none
    /// (`max`) or no cgroup file is readable, as outside a container.
    static func readContainerLimit(paths: [String] = containerLimitPaths) -> Int? {
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
