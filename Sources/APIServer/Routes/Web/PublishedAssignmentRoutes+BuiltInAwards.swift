// APIServer/Routes/Web/PublishedAssignmentRoutes+BuiltInAwards.swift
//
// Per-assignment on/off toggles for the built-in awards (BuiltInAchievements):
// the per-submission badges (Ace / Rally / Tenacious / Swift) and the
// competitive class records (Pathfinder / Trailblazer / Fastest / Minimalist).
//
// GET lists all built-ins with their current enabled state for this assignment;
// PUT stores the DISABLED-id set in the manifest (`disabledBuiltInAwardIDs`).
// The award + display paths honor it (skip awarding/showing disabled ones), so
// an instructor can, e.g., turn the competitive records off for a collaborative
// course.  Metadata-only — no retest/validation needed.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    struct BuiltInAwardRow: Content {
        var id: String
        var name: String
        var detail: String
        /// "perSubmission" | "classRecord" — for grouping in the editor.
        var group: String
        var enabled: Bool
    }

    struct BuiltInAwardsBody: Content {
        /// The ids the instructor has disabled for this assignment.
        var disabled: [String]
    }

    struct BuiltInAwardsResponse: Content {
        var awards: [BuiltInAwardRow]
    }

    // MARK: - GET /instructor/:assignmentID/built-in-awards

    @Sendable
    func getBuiltInAwards(req: Request) async throws -> BuiltInAwardsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        return BuiltInAwardsResponse(
            awards: builtInAwardRows(disabled: BuiltInAchievements.disabled(in: setup)))
    }

    // MARK: - PUT /instructor/:assignmentID/built-in-awards

    @Sendable
    func putBuiltInAwards(req: Request) async throws -> BuiltInAwardsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(BuiltInAwardsBody.self)

        // Keep only ids that are real built-in awards; de-dupe + sort for a
        // stable manifest (so cosmetic re-saves don't churn the bytes).
        let validIDs = Set(BuiltInAchievements.all.map(\.id))
        let disabled = Set(body.disabled).intersection(validIDs).sorted()

        try await mutateManifest(setup: setup, on: req.db) { dict in
            if disabled.isEmpty {
                dict.removeValue(forKey: "disabledBuiltInAwardIDs")
            } else {
                dict["disabledBuiltInAwardIDs"] = disabled
            }
        }
        return BuiltInAwardsResponse(awards: builtInAwardRows(disabled: Set(disabled)))
    }

    private func builtInAwardRows(disabled: Set<String>) -> [BuiltInAwardRow] {
        let perSubmissionIDs = Set(BuiltInAchievements.perSubmission.map(\.id))
        return BuiltInAchievements.all.map { award in
            BuiltInAwardRow(
                id: award.id,
                name: award.reward.label,
                detail: award.detail ?? "",
                group: perSubmissionIDs.contains(award.id) ? "perSubmission" : "classRecord",
                enabled: !disabled.contains(award.id))
        }
    }
}
