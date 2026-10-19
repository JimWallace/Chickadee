// APIServer/Services/Hill.swift
//
// Which hill a king-of-the-hill match plays for (docs/lab-groups.md, slice
// 3b): the assignment's one hill, or one lab group's when the activity runs
// once per group. The rules of the hill are the same for both and live in
// `recordActivityMatch`; only the row that holds the hill differs.

import Core
import Fluent
import Foundation

/// The row that holds a hill: `APIActivityChampion` for the assignment's
/// hill, `APIGroupActivityChampion` for a lab group's.
protocol HillHolder: Model {
    var userID: UUID { get set }
    var submissionID: String { get set }
    var crownedAt: Date? { get set }
    var defences: Int { get set }
}

extension APIActivityChampion: HillHolder {}
extension APIGroupActivityChampion: HillHolder {}

enum Hill: Equatable, Sendable {
    case course(testSetupID: String)
    case group(testSetupID: String, groupID: UUID)

    /// The hill a submission plays for: the assignment's, or for an activity
    /// that runs per group, the group of the session the student had joined
    /// when they submitted. Nil for a per-group submission made with no
    /// session open: it plays the bot (or nobody) and takes no hill.
    static func of(
        submissionID: String, testSetupID: String, userID: UUID?, activity: ClassActivity, on db: any Database
    ) async throws -> Hill? {
        guard activity.isPerGroup else { return .course(testSetupID: testSetupID) }
        guard let userID,
            let session = try await ActivitySessionStore.sessionAtSubmission(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
        else { return nil }
        return .group(testSetupID: testSetupID, groupID: session.groupID)
    }

    /// Who holds the hill now; nil when the bot or nobody does.
    func holder(on db: any Database) async throws -> (any HillHolder)? {
        switch self {
        case .course(let testSetupID):
            try await APIActivityChampion.query(on: db)
                .filter(\.$testSetupID == testSetupID)
                .first()
        case .group(let testSetupID, let groupID):
            try await APIGroupActivityChampion.query(on: db)
                .filter(\.$testSetupID == testSetupID)
                .filter(\.$groupID == groupID)
                .first()
        }
    }

    /// Inserts the hill's first holder. False when another crowning landed
    /// first and the unique index kept theirs; any other failure is rethrown.
    func crownFirst(userID: UUID, submissionID: String, on db: any Database) async throws -> Bool {
        let row: any HillHolder =
            switch self {
            case .course(let testSetupID):
                APIActivityChampion(
                    testSetupID: testSetupID, userID: userID, submissionID: submissionID, crownedAt: Date())
            case .group(let testSetupID, let groupID):
                APIGroupActivityChampion(
                    testSetupID: testSetupID, groupID: groupID, userID: userID, submissionID: submissionID,
                    crownedAt: Date())
            }
        do {
            try await row.save(on: db)
            return true
        } catch {
            guard try await holder(on: db) != nil else { throw error }
            return false
        }
    }
}
