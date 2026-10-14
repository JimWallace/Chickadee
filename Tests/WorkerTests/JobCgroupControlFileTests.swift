// Tests/WorkerTests/JobCgroupControlFileTests.swift
//
// `JobCgroup` writes a control file and removes its directory. The mutation
// sweep of 2026-10-13 (#2535) inverted all four comparisons in those two
// functions and nothing failed, because every existing test needs a host with
// delegated cgroups. A plain directory stands in for the cgroup here: the
// kernel is not involved in which descriptor counts as open, how many bytes
// a write must move, or what `rmdir` and `errno` say.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(1))) final class JobCgroupControlFileTests {

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cgroup-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Survivors `:32 RelationalOperatorReplacement` (`descriptor >= 0` to
    /// `<= 0`) and `:35 RelationalOperatorReplacement` (`== bytes.count` to
    /// `!=`). Either one made every successful write throw `cannotWrite`, so
    /// no job cgroup could ever have been set up, and the runner would have
    /// graded without memory limits while its probe said why.
    @Test func aValueIsWrittenToAnExistingControlFile() throws {
        let file = directory.appendingPathComponent("memory.max")
        try "max\n".write(to: file, atomically: true, encoding: .utf8)
        try JobCgroup(directory: directory).write("1073741824", to: "memory.max")
        #expect(try String(contentsOf: file, encoding: .utf8) == "1073741824")
    }

    @Test func aMissingControlFileIsReportedWithItsPath() {
        let cgroup = JobCgroup(directory: directory)
        #expect(throws: JobCgroupError.self) { try cgroup.write("1", to: "pids.max") }
    }

    /// Survivor `:80 RelationalOperatorReplacement` (`lastError == ENOENT` to
    /// `!=`). A cgroup that was already gone would have been retried for a
    /// second and then logged as not removed.
    @Test func removingAnAbsentCgroupIsQuiet() async {
        let gone = JobCgroup(directory: directory.appendingPathComponent("gone", isDirectory: true))
        let capture = RunnerLogCapture()
        await RunnerLogCapture.$current.withValue(capture) { await gone.remove() }
        #expect(capture.events.isEmpty)
    }

    /// Survivor `:78 RelationalOperatorReplacement` (`rmdir(...) == 0` to
    /// `!= 0`). A cgroup the kernel refused to remove would have been
    /// reported as removed at once, with no log line, and would have stayed
    /// in the delegated subtree for every job after it.
    @Test func aCgroupThatCannotBeRemovedIsLoggedAfterTheRetries() async throws {
        let occupied = directory.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "busy".write(to: occupied.appendingPathComponent("cgroup.procs"), atomically: true, encoding: .utf8)
        let capture = RunnerLogCapture()
        await RunnerLogCapture.$current.withValue(capture) { await JobCgroup(directory: occupied).remove() }
        #expect(capture.events == ["job_cgroup_not_removed"])
        #expect(FileManager.default.fileExists(atPath: occupied.path))
    }
}
