// Worker/JobCgroup.swift
//
// The cgroup of one sandboxed command, and why one could not be created. See
// JobCgroups.swift for how the runner finds the delegated subtree.

import Foundation

/// Why a job cgroup could not be created.
enum JobCgroupError: Error, Equatable, CustomStringConvertible {
    case cannotCreate(String, errno: Int32)
    case cannotWrite(String, errno: Int32)

    var description: String {
        switch self {
        case .cannotCreate(let path, let code):
            "cannot create \(path): \(String(cString: strerror(code)))"
        case .cannotWrite(let path, let code):
            "cannot write \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// The cgroup of one sandboxed command.
struct JobCgroup: Sendable, Equatable {
    let directory: URL

    /// Writes `value` to one of the cgroup's control files. A control file is
    /// written in place, never through a temporary file and a rename.
    func write(_ value: String, to file: String) throws(JobCgroupError) {
        let path = directory.appendingPathComponent(file).path
        let descriptor = open(path, O_WRONLY)
        guard descriptor >= 0 else { throw .cannotWrite(path, errno: errno) }
        defer { close(descriptor) }
        let bytes = Array(value.utf8)
        guard bytes.withUnsafeBufferPointer({ Foundation.write(descriptor, $0.baseAddress, $0.count) }) == bytes.count
        else {
            throw .cannotWrite(path, errno: errno)
        }
    }

    /// The contents of the cgroup's `memory.events`, or an empty string.
    var memoryEvents: String {
        (try? String(contentsOf: directory.appendingPathComponent("memory.events"), encoding: .utf8)) ?? ""
    }

    /// The `oom_kill` count in the contents of a `memory.events` file: how
    /// many processes in the cgroup the kernel stopped for want of memory, at
    /// this cgroup's limit or at a limit above it.
    static func oomKills(inMemoryEvents events: String) -> Int {
        count("oom_kill", inMemoryEvents: events)
    }

    /// The `oom` count in the contents of a `memory.events` file: how many
    /// times this cgroup itself reached its limit. A cgroup above it that
    /// reaches its own limit, such as the container's, counts there, not here.
    static func ownLimitOOMs(inMemoryEvents events: String) -> Int {
        count("oom", inMemoryEvents: events)
    }

    private static func count(_ field: String, inMemoryEvents events: String) -> Int {
        for line in events.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[0] == field, let count = Int(fields[1]) {
                return count
            }
        }
        return 0
    }

    /// Stops every process left in the cgroup and removes it. A process takes
    /// a moment to leave after it is killed, and the kernel refuses to remove
    /// a cgroup that still holds one, so the removal is tried for up to a
    /// second.
    func remove() async {
        try? write("1", to: "cgroup.kill")
        var lastError: Int32 = 0
        for _ in 0..<20 {
            if rmdir(directory.path) == 0 { return }
            lastError = errno
            if lastError == ENOENT { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        writeStructuredRunnerLog(
            event: "job_cgroup_not_removed",
            fields: ["path": directory.path, "error": String(cString: strerror(lastError))])
    }
}
