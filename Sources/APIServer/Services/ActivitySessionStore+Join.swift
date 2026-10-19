// APIServer/Services/ActivitySessionStore+Join.swift
//
// Joining a per-group session by code, and the attendance list that course
// staff read and correct (docs/lab-groups.md, "Presence"). Presence is best
// effort, not proof: the code changes every 30 seconds, so a code sent out of
// the room soon stops working; wrong codes are limited per student; and staff
// see who joined and remove a student who is not in the room.

import Core
import Fluent
import Foundation

extension ActivitySessionStore {

    /// Wrong codes a student may type in `joinFailureWindow` before `/join`
    /// refuses them for the rest of the window. Enough for typing errors as
    /// the code changes, far too few to guess one of 25 to the fifth codes.
    static let joinFailureLimit = 10
    static let joinFailureWindow: TimeInterval = 600

    /// Joins `userID` to the open session whose code at `now` (or just
    /// before) is `code`. A student who is a member of a group joins only
    /// that group's session; a student in no group joins any, and becomes a
    /// member of it in a manual set. A second join of the session the student
    /// is in changes nothing. `network` is the network part of the student's
    /// address (`ClientNetwork.prefix`), nil when unknown.
    @discardableResult
    static func join(
        code: String, userID: UUID, network: String? = nil, now: Date = Date(), on db: any Database
    ) async throws
        -> APIActivitySession
    {
        guard try await recentJoinFailures(userID: userID, now: now, on: db) < joinFailureLimit else {
            throw ActivitySessionError.tooManyAttempts
        }
        let typed = ActivitySessionCode.normalized(code)
        let matching = try await APIActivitySession.query(on: db)
            .filter(\.$closedAt == nil)
            .all()
            .filter { $0.isOpen(at: now) && ActivitySessionCode.matches(typed, secret: $0.codeSecret, at: now) }
        // Two sessions showing one code at once is a chance of a few in ten
        // million; the student types the next code.
        guard !typed.isEmpty, matching.count == 1, let session = matching.first else {
            try await recordJoinFailure(userID: userID, now: now, on: db)
            throw ActivitySessionError.unknownCode
        }
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

        let sessionID = try session.requireID()
        let existing = try await APIActivitySessionAttendance.query(on: db)
            .filter(\.$sessionID == sessionID)
            .filter(\.$userID == userID)
            .first()
        if let removedAt = existing?.removedAt, removedAt >= session.openedAt {
            throw ActivitySessionError.removed
        }
        // Membership first: if it fails, no attendance is left behind.
        let setID = try set.requireID()
        let membership = try await APICourseGroupMembership.query(on: db)
            .filter(\.$setID == setID)
            .filter(\.$userID == userID)
            .first()
        // A member joins only their own group's session; a TA moves a
        // student who goes to another lab on the Groups tab.
        if let membership, membership.groupID != session.groupID {
            let own = try await APICourseGroup.find(membership.groupID, on: db)?.name ?? "another lab"
            throw ActivitySessionError.otherGroup(session: group.name, own: own)
        }
        // Typing the code of the session the student already plays in changes
        // nothing: the join time stays, so a submission made before it still
        // ranks when it is graded (`sessionAtSubmission`).
        if let existing, existing.counts(in: session),
            try await currentSession(assignmentID: session.assignmentID, userID: userID, now: now, on: db)?.id
                == sessionID
        {
            return session
        }
        let placed = set.acceptsManualEdits && membership == nil
        if placed {
            try await CourseGroupStore.setMembership(userID: userID, groupID: group.requireID(), in: set, on: db)
        }
        if let existing {
            // Conditional, so a Remove that lands between the read above and
            // this write is not undone.
            let rowID = try existing.requireID()
            try await APIActivitySessionAttendance.query(on: db)
                .filter(\.$id == rowID)
                .group(.or) { $0.filter(\.$removedAt == nil).filter(\.$removedAt < session.openedAt) }
                .set(\.$joinedAt, to: now)
                .set(\.$removedAt, to: nil)
                .set(\.$placedInGroup, to: existing.placedInGroup || placed)
                .set(\.$joinNetwork, to: network)
                .update()
            if let removedAt = try await APIActivitySessionAttendance.find(rowID, on: db)?.removedAt,
                removedAt >= session.openedAt
            {
                throw ActivitySessionError.removed
            }
        } else {
            // Two joins at once leave one row.
            let row = APIActivitySessionAttendance(sessionID: sessionID, userID: userID, joinedAt: now)
            row.placedInGroup = placed
            row.joinNetwork = network
            try await row.createIgnoringConflict(on: db)
        }
        return session
    }

    /// Every join of the session's current run, removed students included,
    /// oldest first.
    static func attendance(
        of session: APIActivitySession, on db: any Database
    ) async throws
        -> [APIActivitySessionAttendance]
    {
        try await APIActivitySessionAttendance.query(on: db)
            .filter(\.$sessionID == session.requireID())
            .filter(\.$joinedAt >= session.openedAt)
            .sort(\.$joinedAt)
            .all()
    }

    /// How many students play in the session's current run.
    static func joinedCount(of session: APIActivitySession, on db: any Database) async throws -> Int {
        try await attendance(of: session, on: db).filter { $0.removedAt == nil }.count
    }

    /// Removes a student from the session's current run: they stop playing,
    /// and cannot join again until the session starts again. A group
    /// placement that their join made is undone, so the Groups tab shows them
    /// as in no group again, and their rankings in the group are forgotten:
    /// the hill when they hold it, their leaderboard row and their standing,
    /// so no challenger plays them and no board shows them. False when the
    /// student is not in the current run, so nothing changed.
    @discardableResult
    static func remove(
        userID: UUID, from session: APIActivitySession, now: Date = Date(), on db: any Database
    ) async throws -> Bool {
        guard
            let row = try await APIActivitySessionAttendance.query(on: db)
                .filter(\.$sessionID == session.requireID())
                .filter(\.$userID == userID)
                .first(),
            row.counts(in: session)
        else { return false }
        row.removedAt = now
        if row.placedInGroup {
            try await undoPlacement(userID: userID, groupID: session.groupID, on: db)
            row.placedInGroup = false
        }
        try await row.save(on: db)
        if let testSetupID = try await APIAssignment.find(session.assignmentID, on: db)?.testSetupID {
            try await forgetRankings(
                of: userID, assignmentID: session.assignmentID, testSetupID: testSetupID, groupID: session.groupID,
                on: db)
        }
        return true
    }

    /// Deletes the student's rows in one lab group's rankings of the
    /// assignment: the hill, the leaderboard and the standings, and their
    /// composite slot, tile and finished spares in the group's image, so the
    /// student can be dealt again in the lab they are in. A spare that is
    /// still grading stays, so the runner's report finds its job.
    private static func forgetRankings(
        of userID: UUID, assignmentID: UUID, testSetupID: String, groupID: UUID, on db: any Database
    ) async throws {
        // A spare job is owned by no student, so it goes with its row.
        let spares = try await APIGroupCompositeSpare.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$groupID == groupID)
            .filter(\.$userID == userID)
            .filter(\.$finished == true)
            .all()
        let spareJobs =
            spares.isEmpty
            ? [] : try await APISubmission.query(on: db).filter(\.$id ~~ spares.map(\.submissionID)).all()
        for spare in spares { try await spare.delete(on: db) }
        for job in spareJobs {
            try await job.delete(on: db)
            try? FileManager.default.removeItem(atPath: job.zipPath)
            try? FileManager.default.removeItem(atPath: job.zipPath + ".grading")
        }
        try await APIGroupCompositeSlot.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$groupID == groupID)
            .filter(\.$userID == userID)
            .delete()
        try await APICompositeContribution.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$groupID == groupID)
            .filter(\.$userID == userID)
            .delete()
        try await APIGroupActivityChampion.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$groupID == groupID)
            .filter(\.$userID == userID)
            .delete()
        try await APIGroupLeaderboardEntry.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$groupID == groupID)
            .filter(\.$userID == userID)
            .delete()
        try await APIActivityStanding.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$groupID == groupID)
            .filter(\.$userID == userID)
            .delete()
    }

    /// Takes the student out of `groupID` when that is still their group in a
    /// manual set. A placement that staff or a sync changed since is kept.
    private static func undoPlacement(userID: UUID, groupID: UUID, on db: any Database) async throws {
        guard let group = try await APICourseGroup.find(groupID, on: db),
            let set = try await APICourseGroupSet.find(group.setID, on: db), set.acceptsManualEdits,
            try await APICourseGroupMembership.query(on: db)
                .filter(\.$setID == group.setID)
                .filter(\.$userID == userID)
                .first()?.groupID == groupID
        else { return }
        try await CourseGroupStore.setMembership(userID: userID, groupID: nil, in: set, on: db)
    }

    // MARK: - Wrong codes

    private static func recentJoinFailures(userID: UUID, now: Date, on db: any Database) async throws -> Int {
        try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.joinFailure)
            .filter(\.$attemptKey == userID.uuidString)
            .filter(\.$occurredAt > now.addingTimeInterval(-joinFailureWindow))
            .count()
    }

    /// Records a wrong code. Rows older than the window go at the same time,
    /// and the login-attempt sweep removes the rest.
    private static func recordJoinFailure(userID: UUID, now: Date, on db: any Database) async throws {
        try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.joinFailure)
            .filter(\.$attemptKey == userID.uuidString)
            .filter(\.$occurredAt <= now.addingTimeInterval(-joinFailureWindow))
            .delete()
        try await LoginAttempt(scope: LoginAttempt.Scope.joinFailure, attemptKey: userID.uuidString, occurredAt: now)
            .create(on: db)
    }
}
