// APIServer/Routes/Web/InstructorDashboardRoutes+ClassActivity.swift
//
// The Activity section's three lightweight endpoints: the leaderboard
// visibility toggle, the opponent-file picker and the live-session window.
//
//   POST /instructor/:assignmentID/activity
//   POST /instructor/:assignmentID/activity/opponent
//   POST /instructor/:assignmentID/activity/window
//   POST /instructor/:assignmentID/activity/composite
//   POST /instructor/:assignmentID/activity/composite/reference
//   POST /instructor/:assignmentID/tournament/run

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/activity

    /// Publishes or hides the activity's leaderboard. A dedicated lightweight
    /// endpoint for the same reason as the solution-visibility toggle: the
    /// main Save closes and re-validates, which a mid-lab publish must not do.
    /// Display policy only — no regrade, no close. On an assignment with no
    /// activity there is no leaderboard to show, so the request bounces back
    /// to the edit page with an error banner rather than writing anything.
    @Sendable
    func saveActivityLeaderboardSetting(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        guard let current = currentManifestActivity(setup.manifest) else {
            return req.redirect(
                to: "/instructor/\(assignment.publicID)/edit"
                    + "?error=Choose+a+class+activity+kind+and+save+before+publishing+a+leaderboard")
        }
        struct ToggleBody: Content {
            // Checkbox: "on" when checked, absent when not — absence is false.
            var visible: String?
            // The leaderboard page's select sends "visible" or "hidden", which
            // wins over the checkbox because a select cannot be absent.
            var visibility: String?
            var returnTo: String?
        }
        let body = try? await req.decodeContent(ToggleBody.self)
        let visible: Bool
        switch body?.visibility {
        case "visible": visible = true
        case "hidden": visible = false
        default: visible = body?.visible != nil
        }
        do {
            try await ActivityAuthoring.setActivity(
                setup: setup,
                to: current.withLeaderboardVisibility(visible ? .visible : .hidden),
                on: req.db)
        } catch let error as AppError {
            // A class composite refuses a visible board; the page offers no
            // toggle for it, so only a crafted post reaches this.
            let encoded = error.reason.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return req.redirect(to: "/instructor/\(assignment.publicID)/edit?error=" + encoded)
        }
        await AuditLogger.record(
            action: .leaderboardVisibilityChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "leaderboardVisibility": visible ? "visible" : "hidden",
            ],
            on: req
        )
        // The leaderboard page asks to come back to itself. Only that one
        // path is honoured, so the field cannot steer a redirect elsewhere.
        if let returnTo = body?.returnTo, let setupID = setup.id,
            returnTo == "/testsetups/\(setupID)/leaderboard"
        {
            return req.redirect(to: returnTo)
        }
        return req.redirect(
            to: "/instructor/\(assignment.publicID)/edit?notice=Leaderboard+setting+saved")
    }

    // MARK: - POST /instructor/:assignmentID/activity/opponent

    /// Chooses (or clears, with an empty value) the support file the worker
    /// stages as the opponent (docs/class-activities.md). Its own endpoint,
    /// like the visibility toggle, so fixing the bot mid-lab never closes or
    /// re-validates the assignment. `ActivityAuthoring` refuses a file the
    /// setup does not contain and a file on a kind with no opponent; the
    /// refusal comes back as the edit page's error banner.
    @Sendable
    func saveActivityOpponentFile(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        let editPath = "/instructor/\(assignment.publicID)/edit"
        guard let current = currentManifestActivity(setup.manifest) else {
            return req.redirect(
                to: editPath + "?error=Choose+a+class+activity+kind+and+save+before+choosing+an+opponent")
        }
        struct OpponentBody: Content {
            var opponentFile: String?
        }
        let raw = (try? await req.decodeContent(OpponentBody.self))?.opponentFile ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = current.withOpponentFile(trimmed.isEmpty ? nil : trimmed)
        do {
            try await ActivityAuthoring.setActivity(setup: setup, to: next, on: req.db)
        } catch let error as AppError {
            let encoded =
                error.reason.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return req.redirect(to: editPath + "?error=" + encoded)
        }
        await AuditLogger.record(
            action: .activityOpponentFileChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "opponentFile": next.opponentFile ?? "",
            ],
            on: req
        )
        return req.redirect(to: editPath + "?notice=Opponent+file+saved")
    }

    // MARK: - POST /instructor/:assignmentID/activity/window

    /// Sets (or clears, with empty fields) the live-session window
    /// (docs/class-activities.md). Its own lightweight endpoint like the two
    /// above, and for a sharper version of the same reason: a window is set
    /// minutes before the session and adjusted during it, which is exactly
    /// when closing and re-validating the assignment would be worst.
    ///
    /// The fields are `datetime-local`, so they arrive as Toronto wall-clock
    /// and go through `parseDueDate` — the one parser for an
    /// instructor-entered local datetime (#1118).
    @Sendable
    func saveActivityWindow(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        let editPath = "/instructor/\(assignment.publicID)/edit"
        guard let current = currentManifestActivity(setup.manifest) else {
            return req.redirect(
                to: editPath + "?error=Choose+a+class+activity+kind+and+save+before+setting+a+window")
        }
        struct WindowBody: Content {
            var opensAt: String?
            var closesAt: String?
        }
        let body = (try? await req.decodeContent(WindowBody.self)) ?? WindowBody()
        // An empty field clears that bound; a field the parser cannot read is
        // refused rather than silently dropped, since a window half-applied is
        // one an instructor believes is in force.
        for (name, raw) in [("opens at", body.opensAt), ("closes at", body.closesAt)] {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, parseDueDate(trimmed) == nil else { continue }
            let message = "The window's \(name) time could not be read."
            let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return req.redirect(to: editPath + "?error=" + encoded)
        }
        let window = LiveSessionWindow(
            opensAt: parseDueDate(body.opensAt), closesAt: parseDueDate(body.closesAt))
        do {
            try await ActivityAuthoring.setActivity(
                setup: setup, to: current.withWindow(window.isBounded ? window : nil), on: req.db)
        } catch let error as AppError {
            let encoded =
                error.reason.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return req.redirect(to: editPath + "?error=" + encoded)
        }
        await AuditLogger.record(
            action: .activityWindowChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "opensAt": window.opensAtISO ?? "",
                "closesAt": window.closesAtISO ?? "",
            ],
            on: req
        )
        return req.redirect(to: editPath + "?notice=Session+window+saved")
    }

    // MARK: - POST /instructor/:assignmentID/activity/composite

    /// Saves a class composite's settings (docs/class-composite.md). Its own
    /// endpoint, like the window, so a change to the frame rate during a
    /// session never closes or re-validates the assignment.
    ///
    /// A structural field that is absent keeps the stored value. That is how
    /// the lock reads on the page: once a student has submitted, those inputs
    /// render disabled, and a disabled input is not posted. A present field
    /// that does not parse is refused rather than dropped, for the window's
    /// reason: a half-applied change is one the instructor believes is in
    /// force. `ActivityAuthoring` refuses a spec that breaks a rule and a
    /// structural change under live submissions.
    @Sendable
    func saveActivityComposite(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        let editPath = "/instructor/\(assignment.publicID)/edit"
        func refuse(_ message: String) -> Response {
            let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return req.redirect(to: editPath + "?error=" + encoded)
        }
        guard let current = currentManifestActivity(setup.manifest), let stored = current.composite else {
            return refuse("Choose the Class composite kind and save before changing its settings.")
        }
        let body = (try? await req.decodeContent(CompositeFormBody.self)) ?? CompositeFormBody()
        let spec: CompositeSpec
        do {
            spec = try body.spec(keeping: stored)
        } catch let error as CompositeFormBody.Unreadable {
            return refuse(error.message)
        }
        do {
            try await ActivityAuthoring.setActivity(setup: setup, to: current.withComposite(spec), on: req.db)
        } catch let error as AppError {
            return refuse(error.reason)
        }
        await AuditLogger.record(
            action: .activityCompositeChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "compositor": spec.compositor.rawValue,
                "slots": String(spec.layout.slotCount),
            ],
            on: req
        )
        return req.redirect(to: editPath + "?notice=Composite+settings+saved")
    }

    // MARK: - POST /instructor/:assignmentID/activity/composite/reference

    /// Queues the reference render of a class composite: the reference
    /// solution graded once for each slot (docs/class-composite.md, slice 6).
    /// The jobs wait behind every student job. A second press replaces the
    /// earlier render.
    @Sendable
    func prepareCompositeReference(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        let editPath = "/instructor/\(assignment.publicID)/edit"
        let queued: Int
        do {
            queued = try await CompositeReferences.prepare(
                assignment: assignment, setup: setup, app: req.application, on: req.db)
        } catch CompositeReferences.PrepareError.notComposite {
            return req.redirect(to: editPath + "?error=Choose+the+Class+composite+kind+first.")
        } catch CompositeReferences.PrepareError.noSolution {
            return req.redirect(to: editPath + "?error=Save+a+reference+solution+first.")
        }
        await AuditLogger.record(
            action: .activityCompositeChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "referenceJobs": String(queued)],
            on: req
        )
        return req.redirect(to: editPath + "?notice=Reference+render+queued+for+\(queued)+slots")
    }

    // MARK: - POST /instructor/:assignmentID/tournament/run

    /// Starts a tournament on the class as it stands (docs/class-activities.md,
    /// "Tournaments"): snapshots every student's latest submission and
    /// enqueues the first round. Instructor-level, like the kind itself. A
    /// refusal — not a tournament kind, fewer than two entrants — comes back
    /// as the submissions page's error banner.
    @Sendable
    func runTournament(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        let caller = try req.auth.require(APIUser.self)
        let submissionsPath = "/instructor/\(assignment.publicID)/submissions"
        struct RunBody: Content {
            var schedule: String?
        }
        let token = (try? await req.decodeContent(RunBody.self))?.schedule ?? TournamentSchedule.bracket.rawValue
        guard let schedule = TournamentSchedule(rawValue: token) else {
            return req.redirect(to: submissionsPath + "?error=Choose+a+tournament+schedule")
        }
        let run: APITournamentRun
        do {
            run = try await startTournament(setup: setup, schedule: schedule, startedBy: caller.id, on: req.db)
        } catch let error as TournamentStartError {
            let encoded = error.reason.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return req.redirect(to: submissionsPath + "?error=" + encoded)
        }
        await AuditLogger.record(
            action: .tournamentStarted,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "schedule": schedule.rawValue,
                "entrants": String(run.entrants.count),
                "rounds": String(run.roundCount),
            ],
            on: req
        )
        return req.redirect(to: submissionsPath + "?notice=Tournament+started")
    }
}
