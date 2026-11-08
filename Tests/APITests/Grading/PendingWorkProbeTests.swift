// Tests/APITests/Grading/PendingWorkProbeTests.swift
//
// `WorkerJobClaim.hasPendingWork` is the idle runner poll's short-circuit. It
// now runs through SQLKit (#2905) and must still see a pending row of any
// kind, and nothing else.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class PendingWorkProbeTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-pending-probe")
    }

    private func makeSetup() async throws -> String {
        let course = APICourse(code: "PROBE", name: "Probe Course", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: "probe_setup", manifest: "{}", zipPath: app.testSetupsDirectory + "probe_setup.zip",
            courseID: try course.requireID())
        try await setup.save(on: app.db)
        return try setup.requireID()
    }

    private func makeSubmission(id: String, setupID: String, status: SubmissionStatus, kind: String) async throws {
        let submission = APISubmission(
            id: id, testSetupID: setupID, zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1, status: status.rawValue, filename: "submission.zip", userID: nil, kind: kind)
        try await submission.save(on: app.db)
    }

    @Test func anEmptyTableHasNoPendingWork() async throws {
        try await withApp(app) { app in
            let pending = try await WorkerJobClaim.hasPendingWork(on: app.db)
            #expect(!pending)
        }
    }

    @Test func rowsThatAreNotPendingAreNotWork() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup()
            try await makeSubmission(
                id: "probe_done", setupID: setupID, status: .complete, kind: APISubmission.Kind.student)
            try await makeSubmission(
                id: "probe_assigned", setupID: setupID, status: .assigned, kind: APISubmission.Kind.validation)
            let pending = try await WorkerJobClaim.hasPendingWork(on: app.db)
            #expect(!pending)
        }
    }

    @Test(arguments: [
        APISubmission.Kind.student, APISubmission.Kind.validation, APISubmission.Kind.starterValidation,
    ])
    func onePendingRowOfAnyKindIsWork(kind: String) async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup()
            try await makeSubmission(
                id: "probe_done", setupID: setupID, status: .complete, kind: APISubmission.Kind.student)
            try await makeSubmission(id: "probe_pending", setupID: setupID, status: .pending, kind: kind)
            let pending = try await WorkerJobClaim.hasPendingWork(on: app.db)
            #expect(pending)
        }
    }
}
