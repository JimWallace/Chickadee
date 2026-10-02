// APIServer/Routes/Web/InstructorLMSRoutes+BrightSpace.swift
//
// The instructor BrightSpace tab: connection status, the assignment→grade-
// item mapping, the sync-activity log, manual sync actions, and the LEARN
// roster-readiness panel.  Everything here is scoped to the active course.
//
// Connection credentials are server-level (env, ops-managed) and never
// exposed here; the course→org-unit binding is admin-set on the course page.
// This tab is where an instructor wires grade items and watches grades flow.
// The page's view model is assembled by `BrightSpacePagePresenter`
// (Services/); the handlers here resolve the request and act.
//
//   GET  /instructor/brightspace                       → instructor-brightspace.leaf
//   POST /instructor/brightspace/test                  → whoami connection test (JSON)
//   GET  /instructor/brightspace/grade-objects         → [BrightSpaceGradeObject] (dropdown)
//   POST /instructor/brightspace/sync-now              → hard reset: re-queue errored pushes, then sweep immediately
//   POST /instructor/brightspace/reconcile-now         → re-check roster readiness vs LEARN
//   POST /instructor/:assignmentID/brightspace/push-all → re-push every grade for one assignment

import Core
import Fluent
import Foundation
import Vapor

extension InstructorLMSRoutes {

    // MARK: - GET /instructor/brightspace

    @Sendable
    func brightspacePage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        // One-shot flashes from the connect/disconnect/designate actions.
        let flashes = BrightSpacePagePresenter.Flashes(
            success: req.session.data["bs_flash_success"], error: req.session.data["bs_flash_error"])
        req.session.data["bs_flash_success"] = nil
        req.session.data["bs_flash_error"] = nil
        let ctx = try await BrightSpacePagePresenter.context(
            user: user, courseState: courseState, flashes: flashes, on: req.db, application: req.application)
        return try await req.view.render("instructor-brightspace", ctx)
    }

    // MARK: - POST /instructor/brightspace/test

    /// Validates the configured BrightSpace credentials via D2L `whoami`.
    /// Returns JSON the panel renders inline — surfaces auth problems before
    /// any grade push fails.
    @Sendable
    func brightspaceTestConnection(req: Request) async throws -> BrightspaceTestResult {
        let user = try req.auth.require(APIUser.self)
        guard let client = try await activeCourseBrightSpaceClient(req: req, user: user) else {
            return BrightspaceTestResult(
                ok: false, message: "BrightSpace is not connected for this course yet.")
        }
        do {
            let who = try await client.whoami(on: req.application)
            let who2 = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
            return BrightspaceTestResult(ok: true, message: "Connected as \(who2).")
        } catch {
            return BrightspaceTestResult(ok: false, message: "Connection failed: \(error.localizedDescription)")
        }
    }

    /// The BrightSpace client for the active course's designated identity (or
    /// the deployment-wide fallback). Nil when BrightSpace isn't configured or
    /// there's no active course.
    private func activeCourseBrightSpaceClient(
        req: Request, user: APIUser
    ) async throws -> BrightSpaceAPIClient? {
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else { return nil }
        return try await req.application.brightSpaceClient(forCourse: course)
    }

    // MARK: - POST /instructor/brightspace/connect

    /// Connects the requesting instructor's own LEARN account: verifies a pasted
    /// Valence User ID + User Key via `whoami`, stores it against this user, and
    /// — if the active course has no designated identity yet — makes them it
    /// (so grades for this course push as their LEARN account). This is the
    /// per-instructor path for institutions whose Valence Trusted URL is a
    /// central credential harvester rather than this server's own callback.
    @Sendable
    func brightspaceConnectAccount(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        struct ConnectForm: Content {
            let userID: String
            let userKey: String
        }
        let form = try req.content.decode(ConnectForm.self)
        let valenceUserID = form.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let valenceUserKey = form.userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !valenceUserID.isEmpty, !valenceUserKey.isEmpty else {
            req.session.data["bs_flash_error"] = "Both User ID and User Key are required."
            return req.redirect(to: "/instructor/brightspace")
        }
        guard let userUUID = user.id else {
            req.session.data["bs_flash_error"] = "Could not resolve your account."
            return req.redirect(to: "/instructor/brightspace")
        }

        let courseState = try await req.resolveActiveCourse(for: user)
        let connection: BrightSpaceConnectionService.Connection
        do {
            connection = try await BrightSpaceConnectionService.connect(
                userUUID: userUUID, valenceUserID: valenceUserID, valenceUserKey: valenceUserKey,
                activeCourseUUID: courseState.activeCourseUUID, on: req.db, application: req.application)
        } catch BrightSpaceConnectionService.ConnectError.notConfigured {
            req.session.data["bs_flash_error"] = "BrightSpace is not configured on this server."
            return req.redirect(to: "/instructor/brightspace")
        } catch BrightSpaceConnectionService.ConnectError.credentialsRejected(let reason) {
            req.session.data["bs_flash_error"] =
                "Could not verify those credentials against D2L: \(reason)"
            return req.redirect(to: "/instructor/brightspace")
        }

        req.logger.info("BrightSpace connected by \(user.username) as \(connection.identity)")
        await AuditLogger.record(
            action: .brightspaceAccountConnected,
            targetType: .user,
            targetID: userUUID.uuidString,
            metadata: [
                "identity": connection.identity,
                "claimed_course_identity": String(connection.claimedCourse),
            ],
            on: req
        )
        req.session.data["bs_flash_success"] =
            connection.claimedCourse
            ? "Connected as \(connection.identity). This course now syncs grades as your LEARN account."
            : "Connected as \(connection.identity)."
        let response = req.redirect(to: "/instructor/brightspace")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    // MARK: - POST /instructor/brightspace/use-my-identity

    /// Designates the requesting instructor (who must be connected) as the active
    /// course's grade-sync identity — the "reassign" action that lets a connected
    /// co-instructor take over pushes for the course.
    @Sendable
    func brightspaceUseMyIdentity(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userUUID = user.id else {
            req.session.data["bs_flash_error"] = "Could not resolve your account."
            return req.redirect(to: "/instructor/brightspace")
        }
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            req.session.data["bs_flash_error"] = "No active course."
            return req.redirect(to: "/instructor/brightspace")
        }
        do {
            try await BrightSpaceConnectionService.designate(userUUID: userUUID, course: course, on: req.db)
        } catch BrightSpaceConnectionService.DesignateError.notConnected {
            req.session.data["bs_flash_error"] =
                "Connect your LEARN account first, then set it as this course's sync identity."
            return req.redirect(to: "/instructor/brightspace")
        }
        await AuditLogger.record(
            action: .brightspaceSyncIdentitySet,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: ["course_code": course.code],
            on: req
        )
        req.session.data["bs_flash_success"] = "This course now syncs grades as your LEARN account."
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/brightspace/disconnect

    /// Disconnects the requesting instructor's LEARN account (drops the stored
    /// key + cached client). Any course designating them as its sync identity
    /// then defers until someone reconnects — no grade is pushed with a stale key.
    @Sendable
    func brightspaceDisconnectAccount(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userUUID = user.id else {
            req.session.data["bs_flash_error"] = "Could not resolve your account."
            return req.redirect(to: "/instructor/brightspace")
        }
        try await BrightSpaceConnectionService.disconnect(
            userUUID: userUUID, on: req.db, application: req.application)
        await AuditLogger.record(
            action: .brightspaceAccountDisconnected,
            targetType: .user,
            targetID: userUUID.uuidString,
            on: req
        )
        req.session.data["bs_flash_success"] = "Your LEARN account has been disconnected."
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/brightspace/bind-org-unit

    /// Instructor self-serve org-unit binding: sets (or clears) the active
    /// course's D2L org unit, makes the binder the course's grade-sync identity
    /// (the "binder = default" rule), and verifies the org unit with that
    /// instructor's own LEARN key. Requires the instructor to have connected —
    /// verification and every subsequent push run as their key, so a key that
    /// can't see the org unit fails loudly here instead of at grade-push time.
    @Sendable
    func brightspaceBindOrgUnit(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userUUID = user.id else {
            req.session.data["bs_flash_error"] = "Could not resolve your account."
            return req.redirect(to: "/instructor/brightspace")
        }
        struct BindForm: Content { let orgUnitID: String? }
        let rawOrgUnit = (try req.content.decode(BindForm.self).orgUnitID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            req.session.data["bs_flash_error"] = "No active course."
            return req.redirect(to: "/instructor/brightspace")
        }

        // Clearing the binding (blank submit) — leave the sync identity alone.
        if rawOrgUnit.isEmpty {
            try await BrightSpaceCourseBinding.clearOrgUnit(course: course, on: req.db)
            await AuditLogger.record(
                action: .brightspaceOrgUnitCleared,
                targetType: .course,
                targetID: courseUUID.uuidString,
                metadata: ["course_code": course.code],
                on: req
            )
            req.session.data["bs_flash_success"] = "Org-unit binding cleared."
            return req.redirect(to: "/instructor/brightspace")
        }

        let verification: BrightSpaceCourseBinding.Verification
        do {
            verification = try await BrightSpaceCourseBinding.bindOrgUnit(
                course: course, orgUnitID: rawOrgUnit, binderUUID: userUUID,
                on: req.db, application: req.application)
        } catch BrightSpaceCourseBinding.BindError.binderNotConnected {
            req.session.data["bs_flash_error"] =
                "Connect your LEARN account first — the org unit is verified with your key."
            return req.redirect(to: "/instructor/brightspace")
        }
        await AuditLogger.record(
            action: .brightspaceOrgUnitBound,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: ["course_code": course.code, "org_unit": rawOrgUnit],
            on: req
        )

        switch verification {
        case .verified(let name):
            req.session.data["bs_flash_success"] =
                "Linked to \(name) (org unit \(rawOrgUnit)); this course syncs grades as your LEARN account."
        case .unverified:
            req.session.data["bs_flash_success"] = "Org unit \(rawOrgUnit) saved (unverified)."
        case .notFound:
            req.session.data["bs_flash_error"] =
                "Saved org unit \(rawOrgUnit), but D2L reports no such org unit (or your key can't see it) — check the ID."
        case .failed(let reason):
            req.session.data["bs_flash_error"] =
                "Saved org unit \(rawOrgUnit), but couldn't verify it in D2L: \(reason)"
        }
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - GET /instructor/brightspace/grade-objects

    /// Lists the active course's D2L grade items for the mapping dropdown.
    /// Returns an empty array when sync is unconfigured or the course isn't
    /// bound — the panel falls back to free-text entry in that case.
    @Sendable
    func brightspaceGradeObjects(req: Request) async throws -> [BrightSpaceGradeObject] {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db),
            let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty
        else { return [] }
        guard let client = try await req.application.brightSpaceClient(forCourse: course) else { return [] }
        do {
            return try await client.listGradeObjects(orgUnitID: orgUnitID, on: req.application)
        } catch {
            req.logger.warning("BrightSpace grade-objects fetch failed: \(error)")
            return []
        }
    }

    // MARK: - POST /instructor/brightspace/auto-map

    /// Auto-maps unmapped assignments to D2L grade items whose name matches the
    /// assignment title (trimmed, case-insensitive). Only fills empty mappings —
    /// never overrides an existing one — so it's safe to re-run. Saves a manual
    /// pass over the grade book when names already line up.
    @Sendable
    func brightspaceAutoMap(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db),
            let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty,
            let client = try await req.application.brightSpaceClient(forCourse: course)
        else {
            req.session.data["bs_flash_error"] =
                "Link the course to its LEARN org unit first, then auto-map."
            return req.redirect(to: "/instructor/brightspace")
        }

        let mapped: Int
        do {
            mapped = try await BrightSpaceCourseBinding.autoMap(
                courseUUID: courseUUID, orgUnitID: orgUnitID, client: client,
                on: req.db, application: req.application)
        } catch {
            req.session.data["bs_flash_error"] =
                "Couldn't read the LEARN grade book: \(error.localizedDescription)"
            return req.redirect(to: "/instructor/brightspace")
        }

        await AuditLogger.record(
            action: .brightspaceAutoMapped,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: ["course_code": course.code, "mapped_count": String(mapped)],
            on: req
        )
        req.session.data["bs_flash_success"] =
            mapped == 0
            ? "No new matches — every assignment is already mapped or has no grade item with the same name."
            : "Auto-mapped \(mapped) assignment\(mapped == 1 ? "" : "s") by name."
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/brightspace/sync-now

    /// "Sync now" is a hard reset, not just an early trigger of the 60-second
    /// reaper: it first re-queues every push that previously failed *terminally*
    /// (a D2L 4xx, a since-fixed grade item, a student newly added to the
    /// classlist) — which the auto-sweep deliberately leaves alone — and then
    /// runs an immediate sweep so both the retried failures and anything pending
    /// push right away. (Transient failures already retry on their own, so they
    /// need no special handling here.)
    @Sendable
    func brightspaceSyncNow(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        if let courseUUID = courseState.activeCourseUUID {
            try await requeueErroredGradePushes(courseUUID: courseUUID, on: req.db)
        }
        // The requeue above is fast local writes; the sweep itself is one
        // sequential D2L PUT per student, so it runs detached instead of
        // holding this request open (a large class risks a proxy timeout).
        launchBackgroundBrightSpaceSweep(req.application)
        await AuditLogger.record(
            action: .brightspaceSyncNow,
            targetType: .course,
            targetID: courseState.activeCourseUUID?.uuidString,
            on: req
        )
        req.session.data["bs_flash_success"] =
            "Grade sync started — pending grades are pushing to LEARN in the background."
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/brightspace/reconcile-now

    /// Runs the roster-readiness reconcile for the active course immediately
    /// (the manual counterpart to the 10-minute sweep): fetches the LEARN
    /// classlist and re-classifies every enrolled student, persisting their
    /// readiness. Flashes a one-line summary. A no-op when BrightSpace isn't
    /// connected or the course isn't linked to an org unit.
    @Sendable
    func brightspaceReconcileNow(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            req.session.data["bs_flash_error"] = "No active course."
            return req.redirect(to: "/instructor/brightspace")
        }
        guard let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty else {
            req.session.data["bs_flash_error"] =
                "Link this course to its LEARN org unit first."
            return req.redirect(to: "/instructor/brightspace")
        }
        guard let client = try await req.application.brightSpaceClient(forCourse: course) else {
            req.session.data["bs_flash_error"] =
                "BrightSpace isn't connected for this course yet."
            return req.redirect(to: "/instructor/brightspace")
        }
        do {
            let outcome = try await reconcileCourseReadiness(
                course: course, orgUnitID: orgUnitID, client: client,
                on: req.db, application: req.application)
            req.session.data["bs_flash_success"] =
                "Reconciled \(outcome.checked) student\(outcome.checked == 1 ? "" : "s") against LEARN: "
                + "\(outcome.confirmed) confirmed, \(outcome.unreachable) unreachable."
        } catch {
            req.logger.warning("Roster reconcile-now failed: \(error)")
            req.session.data["bs_flash_error"] =
                "Couldn't reconcile against LEARN: \(error.localizedDescription)"
        }
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/:assignmentID/brightspace/push-all

    /// Re-queues every student's grade for one assignment, then sweeps — the
    /// end-of-term / first-time backfill button.
    @Sendable
    func brightspacePushAllForAssignment(req: Request) async throws -> Response {
        // Unlike its active-course-scoped BrightSpace siblings, this takes
        // :assignmentID, so it's drivable cross-course / against an archived
        // course by URL — scope the grade-push backfill to the assignment's own
        // course (#417 Slice D).
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        let submissionIDs = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
            .compactMap(\.id)
        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .all()
        try await requeueForImmediateSync(results, on: req.db)
        // Override-only grades (no-submission students) carry their pending
        // flag on the override row; re-queue those for this assignment too.
        let overrides = try await APIGradeOverride.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .all()
        try await requeueForImmediateSync(overrides, on: req.db)
        // Requeues above are fast local writes; the per-student D2L pushes run
        // detached so a large class can't hold this request to a proxy timeout.
        launchBackgroundBrightSpaceSweep(req.application)
        await AuditLogger.record(
            action: .brightspacePushAll,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "requeued_results": String(results.count),
                "requeued_overrides": String(overrides.count),
            ],
            on: req
        )
        req.session.data["bs_flash_success"] =
            "Queued every grade for “\(assignment.title)” — they're pushing to LEARN in the background."
        return req.redirect(to: "/instructor/brightspace")
    }

}

/// JSON payload for the connection-test button.
struct BrightspaceTestResult: Content {
    let ok: Bool
    let message: String
}
