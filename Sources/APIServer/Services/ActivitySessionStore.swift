// APIServer/Services/ActivitySessionStore.swift
//
// The sessions of per-group class activities (docs/lab-groups.md, slice 2):
// start, end, reopen, and which session a student plays in now. Joining by
// code and the attendance list are in `ActivitySessionStore+Join.swift`.
//
// Rules the store keeps:
//
//   * One session per (assignment, group). Starting an ended session reopens
//     it with a new code secret, so no code of an earlier lab opens the next
//     one. Starting an open session changes nothing.
//   * Only a student who joined plays. Membership decides which group a
//     student in no group joins, not whether they may submit, so every
//     student in the room types the code (docs/lab-groups.md, "Presence").

import Core
import Fluent
import Foundation

enum ActivitySessionStore {

    // MARK: - Reads

    static func session(
        assignmentID: UUID, groupID: UUID, on db: any Database
    ) async throws
        -> APIActivitySession?
    {
        try await APIActivitySession.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$groupID == groupID)
            .first()
    }

    static func sessions(assignmentID: UUID, on db: any Database) async throws -> [APIActivitySession] {
        try await APIActivitySession.query(on: db).filter(\.$assignmentID == assignmentID).all()
    }

    /// The session `userID` plays in at `now`: the open session of this
    /// assignment they most recently joined, or nil. A join from before a
    /// session's latest start does not count: it was a join to an earlier
    /// lab. A student whom staff removed does not count either.
    static func currentSession(
        assignmentID: UUID, userID: UUID, now: Date = Date(), on db: any Database
    ) async throws -> APIActivitySession? {
        let open = try await sessions(assignmentID: assignmentID, on: db).filter { $0.isOpen(at: now) }
        guard !open.isEmpty else { return nil }
        let attended = try await APIActivitySessionAttendance.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$sessionID ~~ open.compactMap(\.id))
            .all()
        let current = attended.filter { row in
            open.contains { row.counts(in: $0) }
        }
        guard let latest = current.max(by: { $0.joinedAt < $1.joinedAt }) else { return nil }
        return open.first { $0.id == latest.sessionID }
    }

    // MARK: - Writes

    /// Starts the group's session, or reopens an ended one with a new code
    /// secret. An open session is returned as it is, so a second Start keeps
    /// the code on the screen. `network` is the presenter's
    /// (`ClientNetwork.prefix`).
    @discardableResult
    static func open(
        assignmentID: UUID, groupID: UUID, by userID: UUID?, network: String? = nil, now: Date = Date(),
        on db: any Database
    ) async throws -> APIActivitySession {
        if let existing = try await session(assignmentID: assignmentID, groupID: groupID, on: db) {
            guard !existing.isOpen(at: now) else { return existing }
            existing.codeSecret = ActivitySessionCode.newSecret()
            existing.openedAt = now
            existing.closedAt = nil
            existing.openedBy = userID
            existing.presenterNetwork = network
            try await existing.save(on: db)
            return existing
        }
        let session = APIActivitySession(
            assignmentID: assignmentID, groupID: groupID, codeSecret: ActivitySessionCode.newSecret(),
            openedAt: now, openedBy: userID)
        session.presenterNetwork = network
        do {
            try await session.create(on: db)
            return session
        } catch  where isInsertConflict(error) {
            // A second Start made the row first: that row is the session.
            guard let made = try await self.session(assignmentID: assignmentID, groupID: groupID, on: db)
            else { throw error }
            return made
        }
    }

    /// Ends the session at `now`. An ended session stays ended.
    static func close(_ session: APIActivitySession, now: Date = Date(), on db: any Database) async throws {
        guard session.closedAt == nil else { return }
        session.closedAt = now
        try await session.save(on: db)
    }

    /// Ends every open session of the assignments on `testSetupID`, for an
    /// activity that no longer runs per group. Without this, turning the
    /// flag on again would bring back an earlier lab's session.
    static func closeOpenSessions(testSetupID: String, now: Date = Date(), on db: any Database) async throws {
        let assignmentIDs = try await APIAssignment.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .all()
            .compactMap(\.id)
        guard !assignmentIDs.isEmpty else { return }
        try await APIActivitySession.query(on: db)
            .filter(\.$assignmentID ~~ assignmentIDs)
            .filter(\.$closedAt == nil)
            .set(\.$closedAt, to: now)
            .update()
    }

    /// Records the network the presenter's screen is on now, when it changed:
    /// the projector may not be the device that pressed Start.
    static func notePresenterNetwork(
        _ network: String?, for session: APIActivitySession, on db: any Database
    ) async throws {
        guard let network, network != session.presenterNetwork else { return }
        session.presenterNetwork = network
        try await session.save(on: db)
    }

    /// Whether the assignment's activity runs once per lab group.
    static func runsPerGroup(_ assignment: APIAssignment, on db: any Database) async throws -> Bool {
        try await APITestSetup.find(assignment.testSetupID, on: db)?.decodedManifest()?.activity?.runsPerGroup
            == true
    }
}
