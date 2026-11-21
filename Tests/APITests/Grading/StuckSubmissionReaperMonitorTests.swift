// Tests/APITests/Grading/StuckSubmissionReaperMonitorTests.swift
//
// The stuck-submission reaper's periodic monitor runs
// `reapStuckAssignedSubmissions` with the default ten-minute cutoff. A job
// assigned an hour ago returns to pending, and a job assigned a minute ago
// stays with its runner. `StuckSubmissionReaperTests` covers the sweep
// function with the clock passed in.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(2))) final class StuckSubmissionReaperMonitorTests {

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-reaper-monitor")
    }

    private func insertAssigned(id: String, workerID: String, assignedAt: Date) async throws {
        let setupID = "setup_reaper_monitor"
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            let setup = APITestSetup(
                id: setupID,
                manifest: TestManifests.workerOnePythonSuite,
                zipPath: app.testSetupsDirectory + "\(setupID).zip",
                courseID: try await app.testCourseID()
            )
            try await setup.save(on: app.db)
        }
        let submission = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1,
            status: SubmissionStatus.assigned.rawValue
        )
        submission.workerID = workerID
        submission.assignedAt = assignedAt
        try await submission.save(on: app.db)
    }

    private func status(of id: String) async throws -> APISubmission {
        try #require(try await APISubmission.find(id, on: app.db))
    }

    @Test func theMonitorReturnsAnOldJobToTheQueueAndLeavesAFreshOne() async throws {
        try await withApp(app) { app in
            try await insertAssigned(
                id: "sub_monitor_old", workerID: "w_gone", assignedAt: Date().addingTimeInterval(-60 * 60))
            try await insertAssigned(
                id: "sub_monitor_fresh", workerID: "w_busy", assignedAt: Date().addingTimeInterval(-60))

            let monitor = app.stuckSubmissionReaperMonitor
            #expect(monitor.name == "Stuck submission reaper")
            await monitor.sweepOnce(application: app)
            let reaped = try await status(of: "sub_monitor_old").status == SubmissionStatus.pending.rawValue

            #expect(reaped)
            let old = try await status(of: "sub_monitor_old")
            #expect(old.workerID == nil)
            #expect(old.assignedAt == nil)
            let fresh = try await status(of: "sub_monitor_fresh")
            #expect(fresh.status == SubmissionStatus.assigned.rawValue)
            #expect(fresh.workerID == "w_busy")
        }
    }
}
