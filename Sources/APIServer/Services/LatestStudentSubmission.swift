// APIServer/Services/LatestStudentSubmission.swift
//
// A student's latest complete submission, as the readers of
// `latestStudentSubmissionsByUser` use it: the classmate chooser (on the claim
// path), the class corpus and a tournament's entrants. It holds the five
// columns they read and nothing else, decoded from the one SQL statement that
// picks the rows, so a whole `APISubmission` (its materialization blob
// included) is never loaded per student. A type rather than a partial Fluent
// model: a reader that wants another column fails to compile, instead of
// reading an unloaded field at run time.

import Foundation

struct LatestStudentSubmission: Sendable, Decodable {
    let id: String
    let userID: UUID
    let submittedAt: Date?
    let filename: String?
    let zipPath: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case submittedAt = "submitted_at"
        case filename
        case zipPath = "zip_path"
    }

    init(id: String, userID: UUID, submittedAt: Date?, filename: String?, zipPath: String) {
        self.id = id
        self.userID = userID
        self.submittedAt = submittedAt
        self.filename = filename
        self.zipPath = zipPath
    }

    /// The same columns of a loaded submission; nil when it has no id or
    /// no owner.
    init?(_ submission: APISubmission) {
        guard let id = submission.id, let userID = submission.userID else { return nil }
        self.init(
            id: id, userID: userID, submittedAt: submission.submittedAt, filename: submission.filename,
            zipPath: submission.zipPath)
    }
}
