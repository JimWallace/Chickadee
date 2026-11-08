// APIServer/Services/SubmissionStatusRow.swift
//
// The columns of one submission that the result view's status poll reads
// (`GET /api/v1/submissions/:id`, #2905).
//
// Every open result view polls this every 2 s while its submission is pending,
// so it is one of the two busiest requests in a deadline. A Fluent `find`
// reflects over and decodes all 19 columns of `APISubmission`; a profile of
// the release server measured that at about 0.9 ms of CPU against 0.37 ms for
// a select of the columns the poll uses.

import Fluent
import Foundation
import SQLKit

/// One submission's status-poll columns: what `SubmissionStatusResponse`
/// returns, plus `user_id` for the owner check.
struct SubmissionStatusRow: Decodable, Sendable, Equatable {
    let id: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int?
    let submittedAt: Date?
    let assignedAt: Date?
    let userID: UUID?

    /// Each raw value is the `APISubmission` field key of the same name.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case testSetupID = "test_setup_id"
        case status
        case attemptNumber = "attempt_number"
        case submittedAt = "submitted_at"
        case assignedAt = "assigned_at"
        case userID = "user_id"
    }

    init(submission: APISubmission) {
        self.id = submission.id ?? ""
        self.testSetupID = submission.testSetupID
        self.status = submission.status
        self.attemptNumber = submission.attemptNumber
        self.submittedAt = submission.submittedAt
        self.assignedAt = submission.assignedAt
        self.userID = submission.userID
    }

    /// The submission with this ID, or nil when there is none. A database
    /// without SQL reads the full model through Fluent.
    static func find(_ id: String, on db: any Database) async throws -> SubmissionStatusRow? {
        guard let sql = db as? (any SQLDatabase) else {
            return try await APISubmission.find(id, on: db).map(SubmissionStatusRow.init(submission:))
        }
        return try await sql.select()
            .columns(CodingKeys.allCases.map(\.rawValue))
            .from(APISubmission.schema)
            .where("id", .equal, id)
            .limit(1)
            .first(decoding: SubmissionStatusRow.self)
    }
}
