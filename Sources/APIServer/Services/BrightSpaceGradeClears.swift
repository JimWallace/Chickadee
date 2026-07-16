// APIServer/Services/BrightSpaceGradeClears.swift
//
// Queued BrightSpace grade REMOVALS (`brightspace_grade_clears`): when an
// instructor clears an override on a previously-synced student who has no
// submissions, the grade must be deleted in D2L, not just stop being pushed.
// The sweep (BrightSpaceSyncSweep.swift) runs `processPendingGradeClears`
// after its pushes; a clear whose (student, setup) is also being pushed the
// same sweep is dropped — the push wins.

import Fluent
import Foundation
import Vapor

/// A queued grade removal plus the rows it needs, pre-resolved from the
/// sweep-wide batch context.
private struct GradeClearTarget {
    let clearRow: APIBrightSpaceGradeClear
    let assignment: APIAssignment?
    let course: APICourse?
    let user: APIUser?
}

extension GradeSyncSweep {
    /// Processes pending `brightspace_grade_clears`: DELETEs each student's grade in
    /// D2L and removes the queue row on success. A clear whose (student, setup) is
    /// also being pushed this sweep is dropped (the push wins). Returns the number
    /// of clears completed.
    func processPendingGradeClears(
        pushedKeys: Set<GradePushKey>,
        cutoff: Date,
        resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?
    ) async throws -> Int {
        let pending = try await APIBrightSpaceGradeClear.query(on: db)
            .filter(\.$brightspaceSyncPending == true)
            .filter(\.$brightspacePendingSince <= cutoff)
            .all()
        guard !pending.isEmpty else { return 0 }

        let context = try await loadSyncContextForKeys(
            setupIDs: pending.map(\.testSetupID), userIDs: pending.map(\.userID))
        var processed = 0
        for clearRow in pending {
            let key = GradePushKey(userID: clearRow.userID, testSetupID: clearRow.testSetupID)
            if pushedKeys.contains(key) {
                // A grade is being (re)pushed for this (student, setup) — drop the clear.
                try await clearRow.delete(on: db)
                continue
            }
            let assignment = context.assignmentsBySetupID[clearRow.testSetupID]
            let target = GradeClearTarget(
                clearRow: clearRow,
                assignment: assignment,
                course: assignment.flatMap { context.coursesByID[$0.courseID] },
                user: context.usersByID[clearRow.userID]
            )
            do {
                let cleared = try await runGradeClear(target: target, resolveClient: resolveClient)
                if cleared { processed += 1 }
            } catch {
                await recordSweepFailure([clearRow], error: error, db: db, logger: application.logger)
            }
        }
        return processed
    }

    /// Removes one student's grade in D2L. Returns false when deferred (no identity
    /// connected yet) so the row stays pending; true on every terminal outcome
    /// (cleared, or a no-op delete because there was nothing in D2L to clear).
    private func runGradeClear(
        target: GradeClearTarget,
        resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?
    ) async throws -> Bool {
        let clearRow = target.clearRow
        // Without a configured grade item + org unit there is nothing in D2L to
        // clear — drop the queue row.
        guard let assignment = target.assignment,
            let gradeObjectID = assignment.brightspaceGradeObjectID, !gradeObjectID.isEmpty,
            let course = target.course,
            let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty
        else {
            try await clearRow.delete(on: db)
            return true
        }
        // A grade source may have reappeared since the clear was queued — the
        // student submitted, or a new override was set. If so, drop the clear; the
        // normal push path will (re)set their grade instead of us removing it.
        if try await studentHasGradeSource(
            testSetupID: clearRow.testSetupID, userID: clearRow.userID)
        {
            try await clearRow.delete(on: db)
            return true
        }

        // Defer until the course has a connected sync identity.
        guard let client = try await resolveClient(course) else { return false }

        let bsUserID = try await resolveBSUserID(for: target.user, orgUnitID: orgUnitID, client: client)
        guard let bsUserID else {
            // No D2L account resolves — nothing to clear.
            try await clearRow.delete(on: db)
            return true
        }

        try await client.clearGrade(
            orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, bsUserID: bsUserID, on: application)

        let entry = APIBrightSpaceSyncLog(
            courseID: course.id, testSetupID: assignment.testSetupID,
            assignmentTitle: assignment.title, userID: clearRow.userID,
            username: target.user?.username ?? clearRow.userID.uuidString,
            orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, points: nil,
            status: .success, detail: "Grade cleared in BrightSpace")
        try? await entry.save(on: db)
        try await clearRow.delete(on: db)
        application.logger.info(
            "BrightSpace grade cleared: user \(clearRow.userID) assignment '\(assignment.title)'")
        return true
    }

    /// True when the student still has a Chickadee grade source for the setup — a
    /// student submission or an instructor override — so a queued grade removal
    /// must NOT run.
    private func studentHasGradeSource(
        testSetupID: String, userID: UUID
    ) async throws -> Bool {
        let hasSubmission =
            try await APISubmission.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .first() != nil
        if hasSubmission { return true }
        return
            try await APIGradeOverride.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$userID == userID)
            .first() != nil
    }
}
