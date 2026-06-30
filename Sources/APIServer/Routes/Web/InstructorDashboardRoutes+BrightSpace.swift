// APIServer/Routes/Web/InstructorDashboardRoutes+BrightSpace.swift
//
// The instructor BrightSpace tab: connection status, the assignment→grade-
// item mapping, the sync-activity log, manual sync actions, and the LEARN
// roster-readiness panel.  Everything here is scoped to the active course.
//
// Connection credentials are server-level (env, ops-managed) and never
// exposed here; the course→org-unit binding is admin-set on the course page.
// This tab is where an instructor wires grade items and watches grades flow.
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
        let ctx = try await buildBrightspaceContext(req: req, user: user)
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
        await runImmediateBrightspaceSweep(req: req)
        return req.redirect(to: "/instructor/brightspace")
    }

    /// Clears the recorded error and re-flags as pending every grade-sync row in
    /// the course (result rows and override-only rows) that previously errored,
    /// back-dating `pendingSince` so the next sweep retries it immediately. The
    /// "hard reset" half of "Sync now".
    private func requeueErroredGradePushes(req: Request, courseUUID: UUID) async throws {
        let resultKeys = try await courseStudentResultIDs(req: req, courseUUID: courseUUID)
        let results =
            resultKeys.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ resultKeys)
                .all()
        for result in results where (result.brightspaceSyncError ?? "").isEmpty == false {
            result.brightspaceSyncPending = true
            result.brightspacePendingSince = Date.distantPast
            result.brightspaceSyncError = nil
            try await result.save(on: req.db)
        }
        // Errored override-only pushes (no-submission students) live on the
        // override row, not a result row — re-queue those too.
        let setupIDs = try await courseSetupIDs(req: req, courseUUID: courseUUID)
        let overrides =
            setupIDs.isEmpty
            ? []
            : try await APIGradeOverride.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
        for override in overrides where (override.brightspaceSyncError ?? "").isEmpty == false {
            override.brightspaceSyncPending = true
            override.brightspacePendingSince = Date.distantPast
            override.brightspaceSyncError = nil
            try await override.save(on: req.db)
        }
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
        let assignment = try await loadAssignment(req)
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
        for result in results {
            result.brightspaceSyncPending = true
            result.brightspacePendingSince = Date.distantPast
            result.brightspaceSyncError = nil
            try await result.save(on: req.db)
        }
        // Override-only grades (no-submission students) carry their pending
        // flag on the override row; re-queue those for this assignment too.
        let overrides = try await APIGradeOverride.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .all()
        for override in overrides {
            override.brightspaceSyncPending = true
            override.brightspacePendingSince = Date.distantPast
            override.brightspaceSyncError = nil
            try await override.save(on: req.db)
        }
        await runImmediateBrightspaceSweep(req: req)
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

    /// Runs a grade-sync sweep immediately, bypassing the debounce window so
    /// a manual "Sync now" click pushes everything currently pending.  No-op
    /// when BrightSpace isn't configured.
    private func runImmediateBrightspaceSweep(req: Request) async {
        guard let app = req.application.brightSpaceAppCredentials else { return }
        let debounce = req.application.brightSpaceSyncConfig?.debounceSecs ?? app.debounceSecs
        // Pass a future `now` so the debounce cutoff lands ahead of every
        // pending row, forcing an immediate push instead of waiting out the
        // window. Each course resolves its designated identity (or the fallback).
        _ = try? await sweepBrightSpaceGradeSync(
            on: req.db,
            debounceSecs: debounce,
            resolveClient: { course in try await req.application.brightSpaceClient(forCourse: course) },
            logger: req.logger,
            application: req.application,
            now: Date().addingTimeInterval(debounce + 1)
        )
    }

    /// Resolves how the active course's grade-sync identity is shown: the display
    /// name (designated instructor, the disconnected instructor's username, or the
    /// deployment-wide fallback), whether that identity still has a stored key, and
    /// whether it's the requesting user.
    private func resolveSyncIdentityDisplay(
        course: APICourse, user: APIUser, req: Request
    ) async throws -> (name: String?, connected: Bool, isMe: Bool) {
        let isMe = course.brightspaceSyncUserID != nil && course.brightspaceSyncUserID == user.id
        if let syncUserID = course.brightspaceSyncUserID {
            if let cred = try await BrightSpaceCredentialStore.load(userID: syncUserID, on: req.db) {
                return (cred.identityName, true, isMe)
            }
            // Designated but disconnected — fall back to the username so the UI
            // can flag that the identity needs to reconnect.
            let username = try await APIUser.find(syncUserID, on: req.db)?.username
            return (username, false, isMe)
        }
        if req.application.brightSpaceClient != nil {
            return ("Deployment default account", true, isMe)
        }
        return (nil, false, isMe)
    }

    /// Assembles the full BrightSpace-tab context for the active course.
    /// The BrightSpace-tab context for the "no active course selected" state —
    /// the per-instructor account + flashes still render, but everything
    /// course-scoped is empty. Extracted so `buildBrightspaceContext` stays
    /// under the body-length limit. `account` groups the requesting
    /// instructor's connection (connected, identity, "since" suffix).
    private func noCourseBrightspaceContext(
        userContext: CurrentUserContext,
        hasActiveCourse: Bool,
        syncEnabled: Bool,
        account: (connected: Bool, identity: String?, since: String?),
        flashSuccess: String?,
        flashError: String?
    ) -> InstructorBrightspaceContext {
        InstructorBrightspaceContext(
            currentUser: userContext, activeInstructorTab: "brightspace",
            hasActiveCourse: hasActiveCourse, courseIsArchived: false,
            brightspaceSyncEnabled: syncEnabled, courseLinked: false,
            orgUnitID: nil, orgUnitName: nil,
            accountConnected: account.connected, accountIdentity: account.identity,
            accountConnectedSince: account.since,
            syncIdentityName: nil, syncIdentityIsMe: false,
            syncIdentityConnected: false, syncIdentityNeedsReconnect: false,
            flashSuccess: flashSuccess, flashError: flashError,
            canSyncNow: false,
            assignmentRows: [], hasAssignments: false,
            logRows: [], hasLog: false,
            summary: BrightspaceSyncSummary(synced: 0, pending: 0, errored: 0),
            canReconcile: false,
            readiness: BrightspaceReadinessSummary(
                confirmed: 0, unconfirmed: 0, unreachable: 0,
                lastCheckedText: "Never", hasBeenChecked: false),
            unreachableStudents: [], hasUnreachable: false)
    }

    private func buildBrightspaceContext(
        req: Request, user: APIUser
    ) async throws
        -> InstructorBrightspaceContext
    {
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user, activeCourse: courseState.active, enrolledCourses: courseState.all)
        // "Enabled" = configured at the app level (URL/App ID/App Key); a user
        // key may still be awaited via per-instructor connect.
        let syncEnabled = req.application.brightSpaceAppCredentials != nil

        // One-shot flashes from the connect/disconnect/designate actions.
        let flashSuccess = req.session.data["bs_flash_success"]
        let flashError = req.session.data["bs_flash_error"]
        req.session.data["bs_flash_success"] = nil
        req.session.data["bs_flash_error"] = nil

        let fmt = waterlooDateTimeFormatter()

        // This instructor's own LEARN connection (course-independent).
        let myCredential: APIBrightSpaceCredential?
        if let uid = user.id {
            myCredential = try await BrightSpaceCredentialStore.load(userID: uid, on: req.db)
        } else {
            myCredential = nil
        }
        let accountConnected = myCredential != nil
        let accountIdentity = myCredential?.identityName
        // Pre-rendered " (since …)" suffix (empty when nil) so the template
        // interpolates it directly — avoids an inline `#if` in the middle of a
        // sentence, which LeafKit 1.14.2 mis-parses.
        let accountConnectedSince = myCredential?.capturedAt.map { " (since \(fmt.string(from: $0)))" }

        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return noCourseBrightspaceContext(
                userContext: userContext, hasActiveCourse: courseState.active != nil,
                syncEnabled: syncEnabled,
                account: (accountConnected, accountIdentity, accountConnectedSince),
                flashSuccess: flashSuccess, flashError: flashError)
        }

        let orgUnitID = course.brightspaceOrgUnitID
        let courseLinked = !(orgUnitID ?? "").isEmpty

        // How the course's grade-sync identity is shown + whether it's still connected.
        let syncIdentity = try await resolveSyncIdentityDisplay(course: course, user: user, req: req)
        let syncIdentityName = syncIdentity.name
        let syncIdentityConnected = syncIdentity.connected
        let syncIdentityIsMe = syncIdentity.isMe

        // Assignments, sorted to match the dashboard ordering.
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()
            .sorted { lhs, rhs in
                switch (lhs.sortOrder, rhs.sortOrder) {
                case (let l?, let r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
        let setupIDs = Array(Set(assignments.map(\.testSetupID)))

        // Recent log rows for this course (most recent first, capped).
        let logModels = try await APIBrightSpaceSyncLog.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .sort(\.$attemptedAt, .descending)
            .range(..<50)
            .all()

        // Latest log per test setup → per-assignment status badge.
        var latestBySetup: [String: APIBrightSpaceSyncLog] = [:]
        for log in logModels where latestBySetup[log.testSetupID] == nil {
            latestBySetup[log.testSetupID] = log
        }

        let (summary, perSetupCounts) = try await brightspaceSyncSummary(
            req: req, courseUUID: courseUUID, setupIDs: setupIDs)
        let (readiness, unreachableStudents) = try await brightspaceReadiness(
            req: req, courseUUID: courseUUID, fmt: fmt)

        let assignmentRows = brightspaceAssignmentRows(
            assignments: assignments, latestBySetup: latestBySetup,
            perSetupCounts: perSetupCounts, fmt: fmt)

        let logRows = logModels.map { log -> BrightspaceLogRow in
            BrightspaceLogRow(
                attemptedAt: log.attemptedAt.map { fmt.string(from: $0) } ?? "—",
                username: log.username,
                assignmentTitle: log.assignmentTitle,
                points: log.points.map { String(format: "%.1f", $0) } ?? "—",
                status: log.status,
                detail: log.detail)
        }

        return InstructorBrightspaceContext(
            currentUser: userContext, activeInstructorTab: "brightspace",
            hasActiveCourse: true, courseIsArchived: course.isArchived,
            brightspaceSyncEnabled: syncEnabled, courseLinked: courseLinked,
            orgUnitID: orgUnitID, orgUnitName: course.brightspaceOrgUnitName,
            accountConnected: accountConnected, accountIdentity: accountIdentity,
            accountConnectedSince: accountConnectedSince,
            syncIdentityName: syncIdentityName, syncIdentityIsMe: syncIdentityIsMe,
            syncIdentityConnected: syncIdentityConnected,
            syncIdentityNeedsReconnect: syncIdentityName != nil && !syncIdentityConnected,
            flashSuccess: flashSuccess, flashError: flashError,
            canSyncNow: syncEnabled && !course.isArchived,
            assignmentRows: assignmentRows, hasAssignments: !assignmentRows.isEmpty,
            logRows: logRows, hasLog: !logRows.isEmpty,
            summary: summary, canReconcile: courseLinked && !course.isArchived,
            readiness: readiness,
            unreachableStudents: unreachableStudents, hasUnreachable: !unreachableStudents.isEmpty)
    }

    /// Builds the per-assignment mapping rows: grade-item ID, latest-sync badge,
    /// and the per-assignment synced/pending/errored rollup (from `perSetupCounts`).
    private func brightspaceAssignmentRows(
        assignments: [APIAssignment],
        latestBySetup: [String: APIBrightSpaceSyncLog],
        perSetupCounts: [String: SetupSyncCounts],
        fmt: DateFormatter
    ) -> [BrightspaceAssignmentRow] {
        assignments.map { a in
            let last = latestBySetup[a.testSetupID]
            let counts = perSetupCounts[a.testSetupID] ?? SetupSyncCounts()
            return BrightspaceAssignmentRow(
                assignmentID: a.publicID,
                title: a.title,
                gradeObjectID: a.brightspaceGradeObjectID ?? "",
                syncExcluded: a.brightspaceSyncExcluded == true,
                lastSyncText: last?.attemptedAt.map { fmt.string(from: $0) } ?? "—",
                lastSyncStatus: last?.status ?? "none",
                lastSyncDetail: last?.detail,
                syncedCount: counts.synced,
                pendingCount: counts.pending,
                erroredCount: counts.errored,
                hasSyncActivity: counts.synced + counts.pending + counts.errored > 0,
                hasPending: counts.pending > 0,
                hasErrored: counts.errored > 0)
        }
    }

    /// Per-test-setup grade-sync rollup, counting **distinct students** (not
    /// rows), each bucketed once by the state of their most recent grade-sync
    /// attempt.  The buckets are mutually exclusive so a student shows up in
    /// exactly one — the instructor reads "Synced" as "students currently
    /// delivered to LEARN" and "Failed" as "students who need a fix", not a
    /// running tally of every historical push.
    private struct SetupSyncCounts {
        var synced = 0
        var pending = 0
        var errored = 0

        /// Buckets one student by their latest attempt's state. A recorded error
        /// means the most recent push failed (needs attention); else a synced
        /// timestamp means it's delivered; else it's still queued.
        mutating func add(error: String?, syncedAt: Date?, pending isPending: Bool) {
            if (error ?? "").isEmpty == false {
                errored += 1
            } else if syncedAt != nil {
                synced += 1
            } else if isPending {
                pending += 1
            }
        }
    }

    /// One student's most-recent grade-sync attempt for a test setup, used to
    /// dedupe the per-assignment counts down to distinct students.
    private struct LatestSyncState {
        var attemptedAt: Date
        var error: String?
        var syncedAt: Date?
        var pending: Bool
    }

    /// Computes the per-assignment Synced/Failed rollup and the headline summary,
    /// counting **distinct students by their most recent attempt** rather than
    /// summing every historical result row.  For a student with submissions, the
    /// latest result row (by `receivedAt`) reflects the outcome of their last
    /// grade push; a no-submission student's grade rides on the override row, so
    /// that row's state is used when no result covers them.
    private func brightspaceSyncSummary(
        req: Request,
        courseUUID: UUID,
        setupIDs: [String]
    ) async throws -> (BrightspaceSyncSummary, [String: SetupSyncCounts]) {
        // (setupID, userID) → that student's most-recent sync state.
        struct StudentKey: Hashable {
            let setupID: String
            let userID: UUID
        }
        var latestByStudent: [StudentKey: LatestSyncState] = [:]

        // Map each student submission to its (setup, student) so a result row
        // resolves to the student whose grade it carries.
        let submissions =
            setupIDs.isEmpty
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .all()
        var keyBySubmissionID: [String: StudentKey] = [:]
        for submission in submissions {
            if let id = submission.id, let userID = submission.userID {
                keyBySubmissionID[id] = StudentKey(setupID: submission.testSetupID, userID: userID)
            }
        }

        // Keep each student's latest result row (highest `receivedAt`).
        let submissionIDs = Array(keyBySubmissionID.keys)
        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .all()
        for result in results {
            guard let key = keyBySubmissionID[result.submissionID] else { continue }
            let received = result.receivedAt ?? Date.distantPast
            if let existing = latestByStudent[key], existing.attemptedAt >= received { continue }
            latestByStudent[key] = LatestSyncState(
                attemptedAt: received,
                error: result.brightspaceSyncError,
                syncedAt: result.brightspaceSyncedAt,
                pending: result.brightspaceSyncPending == true)
        }

        // Override-only students (no submissions) — their grade rides on the
        // override row. Skip any already covered by a result row: the latest
        // result reflects the pushed grade (override included).
        let overrides =
            setupIDs.isEmpty
            ? []
            : try await APIGradeOverride.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
        for override in overrides {
            let key = StudentKey(setupID: override.testSetupID, userID: override.userID)
            if latestByStudent[key] != nil { continue }
            latestByStudent[key] = LatestSyncState(
                attemptedAt: override.brightspacePendingSince ?? Date.distantPast,
                error: override.brightspaceSyncError,
                syncedAt: override.brightspaceSyncedAt,
                pending: override.brightspaceSyncPending == true)
        }

        var perSetup: [String: SetupSyncCounts] = [:]
        for (key, state) in latestByStudent {
            perSetup[key.setupID, default: SetupSyncCounts()].add(
                error: state.error, syncedAt: state.syncedAt, pending: state.pending)
        }

        var synced = 0
        var pending = 0
        var errored = 0
        for counts in perSetup.values {
            synced += counts.synced
            pending += counts.pending
            errored += counts.errored
        }

        let summary = BrightspaceSyncSummary(synced: synced, pending: pending, errored: errored)
        return (summary, perSetup)
    }

    /// Builds the LEARN roster-readiness panel for the active course from the
    /// persisted per-enrollment status (maintained by the readiness sweep):
    /// confirmed / unconfirmed / unreachable counts, the last-checked time, and
    /// the list of unreachable students with the reason. Replaces the old
    /// log-heuristic "unmapped students" view with the authoritative classlist
    /// reconcile.
    private func brightspaceReadiness(
        req: Request, courseUUID: UUID, fmt: DateFormatter
    ) async throws -> (BrightspaceReadinessSummary, [BrightspaceReadinessRow]) {
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .all()
            .filter { $0.role == .student }
        guard !enrollments.isEmpty else {
            return (
                BrightspaceReadinessSummary(
                    confirmed: 0, unconfirmed: 0, unreachable: 0,
                    lastCheckedText: "Never", hasBeenChecked: false), []
            )
        }

        let userIDs = enrollments.map(\.userID)
        let users = try await APIUser.query(on: req.db)
            .filter(\.$id ~~ userIDs)
            .filter(\.$role == UserRole.student.rawValue)
            .all()
        var userByID: [UUID: APIUser] = [:]
        for user in users {
            if let id = user.id { userByID[id] = user }
        }

        var confirmed = 0
        var unconfirmed = 0
        var unreachable: [BrightspaceReadinessRow] = []
        var lastChecked: Date?
        for enrollment in enrollments {
            guard let student = userByID[enrollment.userID] else { continue }
            if let checked = enrollment.brightspaceCheckedAt {
                lastChecked = max(lastChecked ?? checked, checked)
            }
            switch enrollment.learnSyncReadiness {
            case .confirmed: confirmed += 1
            case .unconfirmed: unconfirmed += 1
            case .unreachable:
                let uid = enrollment.userID.uuidString
                unreachable.append(
                    BrightspaceReadinessRow(
                        username: student.username,
                        displayName: student.displayName ?? student.username,
                        detail: enrollment.brightspaceSyncDetail ?? "Not on the LEARN classlist.",
                        userID: uid,
                        unenrollURL: "/courses/\(courseUUID.uuidString)/unenroll/\(uid)"))
            }
        }
        unreachable.sort { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }

        let summary = BrightspaceReadinessSummary(
            confirmed: confirmed, unconfirmed: unconfirmed, unreachable: unreachable.count,
            lastCheckedText: lastChecked.map { fmt.string(from: $0) } ?? "Never",
            hasBeenChecked: lastChecked != nil)
        return (summary, unreachable)
    }
}

/// JSON payload for the connection-test button.
struct BrightspaceTestResult: Content {
    let ok: Bool
    let message: String
}
