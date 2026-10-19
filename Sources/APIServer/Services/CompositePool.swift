// APIServer/Services/CompositePool.swift
//
// Which pool of slots a class composite deals from (docs/lab-groups.md, slice
// 4): the assignment's one image, or one lab group's when the activity runs
// once per group. Each group deals its own slots, so two groups hold the same
// slot numbers. A student holds one slot per assignment, in whichever pool
// dealt it. The rules of dealing and of spares are the same for both and live
// in `CompositeSlots` and `CompositeSpares`; only the tables that hold the
// slots and the spares differ.

import Core
import Fluent
import Foundation

/// The row that holds a spare: `APICompositeSpare` for the assignment's
/// image, `APIGroupCompositeSpare` for a lab group's.
protocol CompositeSpareRow: Model {
    var userID: UUID { get set }
    var slot: Int { get set }
    var submissionID: String { get set }
    var data: String? { get set }
    var passed: Bool { get set }
    var finished: Bool { get set }
    var updatedAt: Date? { get set }
}

extension APICompositeSpare: CompositeSpareRow {}
extension APIGroupCompositeSpare: CompositeSpareRow {}

enum CompositePool: Equatable, Sendable {
    case course(assignmentID: UUID)
    case group(assignmentID: UUID, groupID: UUID)

    var assignmentID: UUID {
        switch self {
        case .course(let assignmentID), .group(let assignmentID, _): assignmentID
        }
    }

    /// The lab group, or nil for the whole class.
    var groupID: UUID? {
        switch self {
        case .course: nil
        case .group(_, let groupID): groupID
        }
    }

    /// One dealt slot, from either table.
    struct Dealt: Equatable, Sendable {
        let userID: UUID
        let slot: Int
        let round: Int
    }

    /// The pool's dealt slots, or one student's.
    func dealt(onlyUserID: UUID? = nil, on db: any Database) async throws -> [Dealt] {
        switch self {
        case .course(let assignmentID):
            let query = APICompositeSlot.query(on: db).filter(\.$assignmentID == assignmentID)
            if let onlyUserID { query.filter(\.$userID == onlyUserID) }
            return try await query.all().map { Dealt(userID: $0.userID, slot: $0.slot, round: $0.round) }
        case .group(let assignmentID, let groupID):
            let query = APIGroupCompositeSlot.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$groupID == groupID)
            if let onlyUserID { query.filter(\.$userID == onlyUserID) }
            return try await query.all().map { Dealt(userID: $0.userID, slot: $0.slot, round: $0.round) }
        }
    }

    /// Inserts a dealt slot. A unique key refuses a second slot for the
    /// student and a second student for the (round, slot), and the caller
    /// handles that conflict.
    func insert(userID: UUID, slot: Int, round: Int, on db: any Database) async throws {
        switch self {
        case .course(let assignmentID):
            try await APICompositeSlot(assignmentID: assignmentID, userID: userID, slot: slot, round: round)
                .create(on: db)
        case .group(let assignmentID, let groupID):
            try await APIGroupCompositeSlot(
                assignmentID: assignmentID, groupID: groupID, userID: userID, slot: slot, round: round
            ).create(on: db)
        }
    }

    /// The pool's spares, or one student's, lowest slot first.
    func spares(onlyUserID: UUID? = nil, on db: any Database) async throws -> [any CompositeSpareRow] {
        switch self {
        case .course(let assignmentID):
            let query = APICompositeSpare.query(on: db).filter(\.$assignmentID == assignmentID).sort(\.$slot)
            if let onlyUserID { query.filter(\.$userID == onlyUserID) }
            return try await query.all()
        case .group(let assignmentID, let groupID):
            let query = APIGroupCompositeSpare.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$groupID == groupID)
                .sort(\.$slot)
            if let onlyUserID { query.filter(\.$userID == onlyUserID) }
            return try await query.all()
        }
    }

    /// A new spare in the pool, not yet saved. A unique key refuses a second
    /// spare in the slot, and the caller handles that conflict.
    func newSpare(userID: UUID, slot: Int, submissionID: String) -> any CompositeSpareRow {
        switch self {
        case .course(let assignmentID):
            APICompositeSpare(assignmentID: assignmentID, userID: userID, slot: slot, submissionID: submissionID)
        case .group(let assignmentID, let groupID):
            APIGroupCompositeSpare(
                assignmentID: assignmentID, groupID: groupID, userID: userID, slot: slot, submissionID: submissionID)
        }
    }

    /// The spare that a `compositeSpare` job renders, and its pool, from
    /// either table.
    static func spare(
        submissionID: String, on db: any Database
    ) async throws -> (pool: CompositePool, row: any CompositeSpareRow)? {
        if let row = try await APICompositeSpare.query(on: db).filter(\.$submissionID == submissionID).first() {
            return (.course(assignmentID: row.assignmentID), row)
        }
        if let row = try await APIGroupCompositeSpare.query(on: db).filter(\.$submissionID == submissionID).first() {
            return (.group(assignmentID: row.assignmentID, groupID: row.groupID), row)
        }
        return nil
    }

    /// The student's dealt slot and the pool that dealt it, from either
    /// table, or nil when they have none.
    static func dealtSlot(
        assignmentID: UUID, userID: UUID, on db: any Database
    ) async throws -> (pool: CompositePool, slot: Int)? {
        if let row = try await APICompositeSlot.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()
        {
            return (.course(assignmentID: assignmentID), row.slot)
        }
        if let row = try await APIGroupCompositeSlot.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()
        {
            return (.group(assignmentID: assignmentID, groupID: row.groupID), row.slot)
        }
        return nil
    }

    /// The pool a student is dealt into now: the assignment's, or for an
    /// activity that runs per group, the group of the session the student
    /// had joined when they submitted (`submissionID`), else the one they
    /// play in at `now`. Nil for a per-group activity with no such session.
    static func forDeal(
        activity: ClassActivity, assignmentID: UUID, testSetupID: String, userID: UUID, submissionID: String?,
        now: Date = Date(), on db: any Database
    ) async throws -> CompositePool? {
        guard activity.isPerGroup else { return .course(assignmentID: assignmentID) }
        let session =
            if let submissionID {
                try await ActivitySessionStore.sessionAtSubmission(
                    testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
            } else {
                try await ActivitySessionStore.currentSession(
                    assignmentID: assignmentID, userID: userID, now: now, on: db)
            }
        return session.map { .group(assignmentID: assignmentID, groupID: $0.groupID) }
    }
}
