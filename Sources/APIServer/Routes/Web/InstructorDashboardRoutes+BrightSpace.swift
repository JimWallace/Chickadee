// APIServer/Routes/Web/InstructorDashboardRoutes+BrightSpace.swift
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

extension InstructorDashboardRoutes {

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
        guard let appCreds = req.application.brightSpaceAppCredentials else {
            req.session.data["bs_flash_error"] = "BrightSpace is not configured on this server."
            return req.redirect(to: "/instructor/brightspace")
        }
        guard let userUUID = user.id else {
            req.session.data["bs_flash_error"] = "Could not resolve your account."
            return req.redirect(to: "/instructor/brightspace")
        }

        // Verify the pasted pair against D2L before persisting, so a bad paste
        // fails loudly here rather than silently breaking grade sync.
        let config = BrightSpaceSyncConfig(app: appCreds, userID: valenceUserID, userKey: valenceUserKey)
        let candidate = BrightSpaceAPIClient(config: config)
        let who: BrightSpaceWhoAmI
        do {
            who = try await candidate.whoami(on: req.application)
        } catch {
            req.logger.warning(
                "BrightSpace connect: whoami verification failed: \(error.localizedDescription)")
            req.session.data["bs_flash_error"] =
                "Could not verify those credentials against D2L: \(error.localizedDescription)"
            return req.redirect(to: "/instructor/brightspace")
        }

        let identity = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
        try await BrightSpaceCredentialStore.save(
            valenceUserID: valenceUserID,
            valenceUserKey: valenceUserKey,
            identityName: identity,
            capturedByUserID: userUUID,
            userID: userUUID,
            on: req.db
        )
        await req.application.brightSpaceClientRegistry.invalidate(userUUID.uuidString)

        // Claim the active course's sync identity if it has none yet (default =
        // whoever connects; any connected instructor can reassign it below).
        var claimedCourse = false
        let courseState = try await req.resolveActiveCourse(for: user)
        if let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db),
            course.brightspaceSyncUserID == nil
        {
            course.brightspaceSyncUserID = userUUID
            try await course.save(on: req.db)
            claimedCourse = true
        }

        req.logger.info("BrightSpace connected by \(user.username) as \(identity)")
        await AuditLogger.record(
            action: .brightspaceAccountConnected,
            targetType: .user,
            targetID: userUUID.uuidString,
            metadata: ["identity": identity, "claimed_course_identity": String(claimedCourse)],
            on: req
        )
        req.session.data["bs_flash_success"] =
            claimedCourse
            ? "Connected as \(identity). This course now syncs grades as your LEARN account."
            : "Connected as \(identity)."
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
        guard try await BrightSpaceCredentialStore.load(userID: userUUID, on: req.db) != nil else {
            req.session.data["bs_flash_error"] =
                "Connect your LEARN account first, then set it as this course's sync identity."
            return req.redirect(to: "/instructor/brightspace")
        }
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            req.session.data["bs_flash_error"] = "No active course."
            return req.redirect(to: "/instructor/brightspace")
        }
        course.brightspaceSyncUserID = userUUID
        try await course.save(on: req.db)
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
        try await BrightSpaceCredentialStore.clear(userID: userUUID, on: req.db)
        await req.application.brightSpaceClientRegistry.invalidate(userUUID.uuidString)
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
            course.brightspaceOrgUnitID = nil
            course.brightspaceOrgUnitName = nil
            try await course.save(on: req.db)
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

        // Binding requires a connected key — the org unit is verified with it,
        // and pushes run as it.
        guard try await BrightSpaceCredentialStore.load(userID: userUUID, on: req.db) != nil else {
            req.session.data["bs_flash_error"] =
                "Connect your LEARN account first — the org unit is verified with your key."
            return req.redirect(to: "/instructor/brightspace")
        }

        // The binder becomes the course's sync identity, then we verify the org
        // unit using their (now course-resolved) key.
        course.brightspaceOrgUnitID = rawOrgUnit
        course.brightspaceSyncUserID = userUUID
        course.brightspaceOrgUnitName = nil
        try await course.save(on: req.db)
        await AuditLogger.record(
            action: .brightspaceOrgUnitBound,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: ["course_code": course.code, "org_unit": rawOrgUnit],
            on: req
        )

        guard let client = try await req.application.brightSpaceClient(forCourse: course) else {
            req.session.data["bs_flash_success"] = "Org unit \(rawOrgUnit) saved (unverified)."
            return req.redirect(to: "/instructor/brightspace")
        }
        do {
            if let info = try await client.getOrgUnit(orgUnitID: rawOrgUnit, on: req.application) {
                course.brightspaceOrgUnitName = info.name
                try await course.save(on: req.db)
                req.session.data["bs_flash_success"] =
                    "Linked to \(info.name) (org unit \(rawOrgUnit)); this course syncs grades as your LEARN account."
            } else {
                req.session.data["bs_flash_error"] =
                    "Saved org unit \(rawOrgUnit), but D2L reports no such org unit (or your key can't see it) — check the ID."
            }
        } catch {
            req.logger.warning("BrightSpace org-unit verification failed for \(rawOrgUnit): \(error)")
            req.session.data["bs_flash_error"] =
                "Saved org unit \(rawOrgUnit), but couldn't verify it in D2L: \(error.localizedDescription)"
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

        let gradeObjects: [BrightSpaceGradeObject]
        do {
            gradeObjects = try await client.listGradeObjects(orgUnitID: orgUnitID, on: req.application)
        } catch {
            req.session.data["bs_flash_error"] =
                "Couldn't read the LEARN grade book: \(error.localizedDescription)"
            return req.redirect(to: "/instructor/brightspace")
        }

        // Index grade items by normalized name; first wins if D2L has duplicates.
        var idByName: [String: String] = [:]
        for object in gradeObjects {
            let key = object.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, idByName[key] == nil { idByName[key] = object.id }
        }

        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()
        var mapped = 0
        for assignment in assignments where (assignment.brightspaceGradeObjectID ?? "").isEmpty {
            let key = assignment.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let objectID = idByName[key] {
                assignment.brightspaceGradeObjectID = objectID
                try await assignment.save(on: req.db)
                mapped += 1
            }
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
            try await requeueErroredGradePushes(req: req, courseUUID: courseUUID)
        }
        // The requeue above is fast local writes; the sweep itself is one
        // sequential D2L PUT per student, so it runs detached instead of
        // holding this request open (a large class risks a proxy timeout).
        launchBackgroundBrightspaceSweep(req.application)
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

    /// Clears the recorded error and re-flags as pending every grade-sync row in
    /// the course (result rows, override-only rows, and queued grade clears)
    /// that previously errored, back-dating `pendingSince` so the next sweep
    /// retries it immediately. The "hard reset" half of "Sync now".
    private func requeueErroredGradePushes(req: Request, courseUUID: UUID) async throws {
        let resultKeys = try await courseStudentResultIDs(req: req, courseUUID: courseUUID)
        let results =
            resultKeys.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ resultKeys)
                .all()
        try await requeueForImmediateSync(
            results.filter { ($0.brightspaceSyncError ?? "").isEmpty == false }, on: req.db)
        // Errored override-only pushes (no-submission students) live on the
        // override row, not a result row — re-queue those too.
        let setupIDs = try await courseSetupIDs(req: req, courseUUID: courseUUID)
        let overrides =
            setupIDs.isEmpty
            ? []
            : try await APIGradeOverride.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
        try await requeueForImmediateSync(
            overrides.filter { ($0.brightspaceSyncError ?? "").isEmpty == false }, on: req.db)
        // Errored grade CLEARS (queued removals) are re-queued too — nothing
        // else touches `brightspace_grade_clears` after a terminal failure, so
        // before this an errored clear lingered forever with an error nobody
        // could see (#1105).
        let clears =
            setupIDs.isEmpty
            ? []
            : try await APIBrightSpaceGradeClear.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
        try await requeueForImmediateSync(
            clears.filter { ($0.brightspaceSyncError ?? "").isEmpty == false }, on: req.db)
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
        launchBackgroundBrightspaceSweep(req.application)
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

    // MARK: - Helpers

    /// Submission IDs (used as result-query keys) for all student submissions
    /// in the active course's test setups.
    private func courseStudentResultIDs(req: Request, courseUUID: UUID) async throws -> [String] {
        let setupIDs = try await courseSetupIDs(req: req, courseUUID: courseUUID)
        guard !setupIDs.isEmpty else { return [] }
        return try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
            .compactMap(\.id)
    }

    /// Distinct test setup IDs for the active course's assignments.  Used to
    /// scope override-row queries (override-only grade pushes) by course.
    private func courseSetupIDs(req: Request, courseUUID: UUID) async throws -> [String] {
        let setupIDs = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()
            .map(\.testSetupID)
        return Array(Set(setupIDs))
    }

    /// Kicks off a grade-sync sweep in a detached background task and returns
    /// immediately, so a manual "Sync now" / "Push all" click never holds the
    /// HTTP request open for the duration of every D2L push — a large class is
    /// dozens of sequential round-trips, which would otherwise risk a
    /// reverse-proxy timeout and leave the instructor staring at a spinner.
    /// The rows are already flagged pending by the caller (a fast local
    /// write), so even if this task dies the 60-second periodic monitor picks
    /// them up. Uses `application.db` (NOT `req.db`, which is request-scoped)
    /// since the task outlives the request, and bypasses the debounce so every
    /// pending row pushes immediately. Failures are recorded per-row by the
    /// sweep itself; a sweep-level throw is logged (it used to be silently
    /// swallowed, #1117). No-op when BrightSpace isn't configured.
    private func launchBackgroundBrightspaceSweep(_ application: Application) {
        guard let app = application.brightSpaceAppCredentials else { return }
        let debounce = application.brightSpaceSyncConfig?.debounceSecs ?? app.debounceSecs
        Task {
            // Each course resolves its designated identity (or the fallback).
            do {
                _ = try await sweepBrightSpaceGradeSync(
                    on: application.db,
                    debounceSecs: debounce,
                    resolveClient: { course in
                        try await application.brightSpaceClient(forCourse: course)
                    },
                    logger: application.logger,
                    application: application,
                    bypassDebounce: true
                )
            } catch {
                application.logger.warning(
                    "BrightSpace background sweep failed: \(error)")
            }
        }
    }
}

/// JSON payload for the connection-test button.
struct BrightspaceTestResult: Content {
    let ok: Bool
    let message: String
}
