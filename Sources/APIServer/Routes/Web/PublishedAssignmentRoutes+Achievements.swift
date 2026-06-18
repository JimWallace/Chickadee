// APIServer/Routes/Web/PublishedAssignmentRoutes+Achievements.swift
//
// Instructor authoring for the composable Achievements editor.
//
// GET returns one editable row per achievement; PUT replaces the manifest's
// `achievements` array wholesale.  The row <-> domain conversion, validation,
// and manifest read/write live in the shared `AchievementsEditing` service so
// the web editor and the MCP get_achievements / update_achievements tools run
// one implementation.  Achievements are server-evaluated and display-only —
// they never change what the suite grades — so, unlike suite edits, this path
// does NOT retest submissions, reschedule validation, or close the assignment.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    /// The editor row types are shared with the MCP tools; these aliases keep the
    /// `PublishedAssignmentRoutes.AchievementInput` / `.ConditionInput` spelling
    /// the web layer (and its tests) use.
    typealias ConditionInput = ConditionRow
    typealias AchievementInput = AchievementRow

    struct AchievementsBody: Content {
        var achievements: [AchievementInput]
    }

    struct AchievementsResponse: Content {
        var achievements: [AchievementInput]
    }

    // MARK: - GET /instructor/:assignmentID/achievements

    @Sendable
    func getAchievements(req: Request) async throws -> AchievementsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        return AchievementsResponse(
            achievements: AchievementsEditing.rows(fromManifest: setup.manifest))
    }

    // MARK: - PUT /instructor/:assignmentID/achievements

    @Sendable
    func putAchievements(req: Request) async throws -> AchievementsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(AchievementsBody.self)
        let rows = try await AchievementsEditing.apply(
            rows: body.achievements, setup: setup, on: req.db)
        return AchievementsResponse(achievements: rows)
    }
}
