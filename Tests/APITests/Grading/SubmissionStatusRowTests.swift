// Tests/APITests/Grading/SubmissionStatusRowTests.swift
//
// The status poll reads `SubmissionStatusRow` through SQLKit in place of the
// full `APISubmission` model (#2905). The row must hold exactly what the model
// holds for its columns, nil values included, so the poll's JSON and its owner
// check are unchanged.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class SubmissionStatusRowTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-status-row")
    }

    private func makeSetup(id: String) async throws -> APITestSetup {
        let course = APICourse(code: "SR_\(id)", name: "Status Row Course", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: id, manifest: "{}", zipPath: app.testSetupsDirectory + "\(id).zip",
            courseID: try course.requireID())
        try await setup.save(on: app.db)
        return setup
    }

    private func makeSubmission(
        id: String, setupID: String, attemptNumber: Int, userID: UUID?, assignedAt: Date?
    ) async throws -> APISubmission {
        let submission = APISubmission(
            id: id, testSetupID: setupID, zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: attemptNumber, status: SubmissionStatus.assigned.rawValue,
            filename: "submission.zip", userID: userID, kind: APISubmission.Kind.student)
        submission.assignedAt = assignedAt
        try await submission.save(on: app.db)
        return submission
    }

    @Test func theRowHoldsWhatTheModelHolds() async throws {
        try await withApp(app) { app in
            let setup = try await makeSetup(id: "status_row_setup")
            let user = APIUser(username: "status_row_student", passwordHash: "x", role: "user")
            try await user.save(on: app.db)
            let full = try await makeSubmission(
                id: "status_row_full", setupID: try setup.requireID(), attemptNumber: 3,
                userID: try user.requireID(), assignedAt: Date(timeIntervalSince1970: 1_800_000_000.5))
            let sparse = try await makeSubmission(
                id: "status_row_sparse", setupID: try setup.requireID(), attemptNumber: 1,
                userID: nil, assignedAt: nil)

            for id in [try full.requireID(), try sparse.requireID()] {
                let model = try #require(try await APISubmission.find(id, on: app.db))
                let row = try #require(try await SubmissionStatusRow.find(id, on: app.db))
                #expect(row == SubmissionStatusRow(submission: model))
            }
            let sparseRow = try #require(try await SubmissionStatusRow.find("status_row_sparse", on: app.db))
            #expect(sparseRow.userID == nil)
            #expect(sparseRow.assignedAt == nil)
        }
    }

    @Test func aMissingSubmissionIsNil() async throws {
        try await withApp(app) { app in
            let missing = try await SubmissionStatusRow.find("no_such_submission", on: app.db)
            #expect(missing == nil)
        }
    }

    /// The model's attempt number is optional although the column is not; a
    /// row without one reads as attempt 1, as the poll always answered.
    /// (`withApp` shuts down the app this class suite makes for every test.)
    @Test func aMissingAttemptNumberReadsAsOne() async throws {
        try await withApp(app) { _ in
            let model = APISubmission(
                id: "unsaved", testSetupID: "setup", zipPath: "unsaved.zip", attemptNumber: 1,
                status: SubmissionStatus.pending.rawValue, filename: nil, userID: nil,
                kind: APISubmission.Kind.student)
            model.attemptNumber = nil
            #expect(SubmissionStatusResponse(row: SubmissionStatusRow(submission: model)).attemptNumber == 1)
        }
    }

    /// Each column the row reads is the model's field key of the same name.
    @Test func everyColumnIsAnAPISubmissionFieldKey() async throws {
        try await withApp(app) { _ in
            let model = APISubmission()
            let keys: [SubmissionStatusRow.CodingKeys: FieldKey] = [
                .id: model.$id.key,
                .testSetupID: model.$testSetupID.key,
                .status: model.$status.key,
                .attemptNumber: model.$attemptNumber.key,
                .submittedAt: model.$submittedAt.$timestamp.key,
                .assignedAt: model.$assignedAt.key,
                .userID: model.$userID.key,
            ]
            #expect(keys.count == SubmissionStatusRow.CodingKeys.allCases.count)
            for (codingKey, fieldKey) in keys {
                #expect(codingKey.rawValue == fieldKey.description)
            }
        }
    }
}
