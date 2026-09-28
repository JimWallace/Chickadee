// APIServer/Routes/Web/InstructorDashboardRoutes+ClassActivity.swift
//
// The Activity section's three lightweight endpoints: the leaderboard
// visibility toggle, the opponent-file picker and the live-session window.
//
//   POST /instructor/:assignmentID/activity
//   POST /instructor/:assignmentID/activity/opponent
//   POST /instructor/:assignmentID/activity/window
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
        }
        let visible = ((try? req.content.decode(ToggleBody.self))?.visible) != nil
        try await ActivityAuthoring.setActivity(
            setup: setup,
            to: current.withLeaderboardVisibility(visible ? .visible : .hidden),
            on: req.db)
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
        let raw = (try? req.content.decode(OpponentBody.self))?.opponentFile ?? ""
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
        let body = (try? req.content.decode(WindowBody.self)) ?? WindowBody()
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
        let token = (try? req.content.decode(RunBody.self))?.schedule ?? TournamentSchedule.bracket.rawValue
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
