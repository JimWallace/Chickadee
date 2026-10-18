// APIServer/Services/ActivitySessionStore.swift
//
// The sessions of per-group class activities (docs/lab-groups.md, slice 2):
// start, end, reopen, join by code, and which session a student plays in now.
//
// Rules the store keeps:
//
//   * One session per (assignment, group). Starting an ended session reopens
//     it with a new code, so a code read off an earlier lab's screen does not
//     open the next one. Starting an open session changes nothing.
//   * A join code names one session, across the whole deployment, which is
//     what lets `/join` take the code alone.
//   * Attendance beats membership. A student who joined a session by code
//     plays in that session's group. A student in no group of a manual set
//     who joins becomes a member of the session's group.

import Core
import Fluent
import Foundation

enum ActivitySessionStore {

    /// The join code's characters: capitals and digits with no look-alike
    /// pair (no 0 and O, 1 and I, 2 and Z, 5 and S, 8 and B), so a code read
    /// off a projector is typed right the first time.
    static let codeAlphabet: [Character] = Array("ACDEFGHJKMNPQRTUVWXY34679")
    static let codeLength = 5

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

    /// The student's group in the course's group set, or nil.
    static func group(of userID: UUID, courseID: UUID, on db: any Database) async throws -> APICourseGroup? {
        guard let setID = try await CourseGroupStore.sets(courseID: courseID, on: db).first?.id,
            let membership = try await APICourseGroupMembership.query(on: db)
                .filter(\.$setID == setID)
                .filter(\.$userID == userID)
                .first()
        else { return nil }
        return try await APICourseGroup.find(membership.groupID, on: db)
    }

    /// The session `userID` plays in at `now`: the open session of this
    /// assignment they most recently joined by code, else the open session of
    /// their own group, else nil. A join from before a session's latest start
    /// does not count: it was a join to an earlier lab.
    static func currentSession(
        assignmentID: UUID, courseID: UUID, userID: UUID, now: Date = Date(), on db: any Database
    ) async throws -> APIActivitySession? {
        let open = try await sessions(assignmentID: assignmentID, on: db).filter { $0.isOpen(at: now) }
        guard !open.isEmpty else { return nil }
        let attended = try await APIActivitySessionAttendance.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$sessionID ~~ open.compactMap(\.id))
            .all()
        let current = attended.filter { row in
            open.contains { $0.id == row.sessionID && row.joinedAt >= $0.openedAt }
        }
        if let latest = current.max(by: { $0.joinedAt < $1.joinedAt }),
            let session = open.first(where: { $0.id == latest.sessionID })
        {
            return session
        }
        guard let groupID = try await group(of: userID, courseID: courseID, on: db)?.id else { return nil }
        return open.first { $0.groupID == groupID }
    }

    // MARK: - Writes

    /// Starts the group's session, or reopens an ended one with a new code.
    /// An open session is returned as it is, so a second Start keeps the code
    /// on the screen. A code that is already taken is drawn again.
    @discardableResult
    static func open(
        assignmentID: UUID, groupID: UUID, by userID: UUID?, now: Date = Date(), on db: any Database
    ) async throws -> APIActivitySession {
        let attempts = 8
        for attempt in 1...attempts {
            let existing = try await session(assignmentID: assignmentID, groupID: groupID, on: db)
            if let existing, existing.isOpen(at: now) { return existing }
            let session =
                existing
                ?? APIActivitySession(
                    assignmentID: assignmentID, groupID: groupID, joinCode: "", openedAt: now, openedBy: userID)
            session.joinCode = newCode()
            session.openedAt = now
            session.closedAt = nil
            session.openedBy = userID
            do {
                try await session.save(on: db)
                return session
            } catch let error as any DatabaseError where error.isConstraintFailure && attempt < attempts {
                // A taken code, or a second Start that made the row first:
                // read again and draw again.
                continue
            }
        }
        throw ActivitySessionStoreError.noFreeCode
    }

    /// Ends the session at `now`. An ended session stays ended.
    static func close(_ session: APIActivitySession, now: Date = Date(), on db: any Database) async throws {
        guard session.closedAt == nil else { return }
        session.closedAt = now
        try await session.save(on: db)
    }

    /// Joins `userID` to the open session named by `code`, in any letter case
    /// and with spaces ignored. A second join moves the student back to this
    /// session from any other they joined since.
    @discardableResult
    static func join(
        code: String, userID: UUID, now: Date = Date(), on db: any Database
    ) async throws
        -> APIActivitySession
    {
        let normalized = String(code.uppercased().filter { !$0.isWhitespace && $0 != "-" })
        guard !normalized.isEmpty,
            let session = try await APIActivitySession.query(on: db).filter(\.$joinCode == normalized).first()
        else { throw ActivitySessionError.unknownCode }
        guard session.isOpen(at: now) else { throw ActivitySessionError.sessionClosed }
        guard let assignment = try await APIAssignment.find(session.assignmentID, on: db),
            let group = try await APICourseGroup.find(session.groupID, on: db),
            let set = try await APICourseGroupSet.find(group.setID, on: db)
        else { throw ActivitySessionError.unknownCode }
        // A removed group, or an activity no longer run per group, has no
        // session to join, whatever the row says.
        guard group.removedAt == nil, try await runsPerGroup(assignment, on: db),
            try await APICourse.find(assignment.courseID, on: db)?.isArchived == false
        else { throw ActivitySessionError.sessionClosed }
        let enrollment = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == assignment.courseID)
            .filter(\.$userID == userID)
            .first()
        guard enrollment?.role == .student else { throw ActivitySessionError.notAStudent }

        // Membership first: if it fails, no attendance is left behind.
        let setID = try set.requireID()
        let membership = try await APICourseGroupMembership.query(on: db)
            .filter(\.$setID == setID)
            .filter(\.$userID == userID)
            .first()
        if set.acceptsManualEdits, membership == nil {
            try await CourseGroupStore.setMembership(userID: userID, groupID: group.requireID(), in: set, on: db)
        }
        try await recordAttendance(sessionID: session.requireID(), userID: userID, now: now, on: db)
        return session
    }

    /// Sets the student's attendance row to `now`, making it if it is not
    /// there. Two joins at once leave one row.
    private static func recordAttendance(
        sessionID: UUID, userID: UUID, now: Date, on db: any Database
    ) async throws {
        let existing = try await APIActivitySessionAttendance.query(on: db)
            .filter(\.$sessionID == sessionID)
            .filter(\.$userID == userID)
            .first()
        if let existing {
            existing.joinedAt = now
            try await existing.save(on: db)
        } else {
            try await APIActivitySessionAttendance(sessionID: sessionID, userID: userID, joinedAt: now)
                .createIgnoringConflict(on: db)
        }
    }

    /// Whether the assignment's activity runs once per lab group.
    static func runsPerGroup(_ assignment: APIAssignment, on db: any Database) async throws -> Bool {
        try await APITestSetup.find(assignment.testSetupID, on: db)?.decodedManifest()?.activity?.runsPerGroup
            == true
    }

    /// A fresh code from `codeAlphabet`.
    static func newCode() -> String {
        String((0..<codeLength).map { _ in codeAlphabet[Int.random(in: 0..<codeAlphabet.count)] })
    }
}
