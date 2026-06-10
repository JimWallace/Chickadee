// APIServer/Routes/Web/PublishedAssignmentRoutes+Achievements.swift
//
// Instructor authoring for class-wide goals (a kind of Achievement).
//
// GET returns the assignment's current class goals as editable rows; PUT
// replaces the class-goal set in the manifest.  Class goals are
// server-evaluated and display-only — they never change what the suite grades —
// so, unlike suite edits, this path does NOT retest submissions, reschedule
// validation, or close the assignment.  It just rewrites the manifest's
// `achievements` array (preserving any non-class-goal achievements).

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    /// One editable class-goal row from the editor.
    struct ClassGoalInput: Content {
        var id: String?
        var name: String
        /// Per-student grade threshold, 0–100 (% of the assignment grade).
        var thresholdPercent: Double
        /// Share of the class that must reach the threshold, 0–100.
        var classPercent: Double
        /// Positive bonus points (extra credit, capped at 100% at grading time).
        var bonusPoints: Int
    }

    struct AchievementsBody: Content {
        /// Legacy class-goals-card shape (replaces only the class-goal subset).
        var goals: [ClassGoalInput]?
        /// Unified shape (replaces the entire achievements list).  Wins when present.
        var achievements: [AchievementInput]?
    }

    struct AchievementsResponse: Content {
        var goals: [ClassGoalInput]
        var achievements: [AchievementInput]
    }

    // MARK: - GET /instructor/:assignmentID/achievements

    @Sendable
    func getAchievements(req: Request) async throws -> AchievementsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        return makeAchievementsResponse(fromManifest: setup.manifest)
    }

    private func makeAchievementsResponse(fromManifest manifest: String) -> AchievementsResponse {
        AchievementsResponse(
            goals: classGoalRows(fromManifest: manifest),
            achievements: unifiedAchievementRows(fromManifest: manifest))
    }

    // MARK: - PUT /instructor/:assignmentID/achievements

    @Sendable
    func putAchievements(req: Request) async throws -> AchievementsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(AchievementsBody.self)

        let merged: [Achievement]
        let isUnified = body.achievements != nil
        if let unified = body.achievements {
            // Unified shape: replace the entire achievements list.
            merged = try unified.map { try achievement(fromUnified: $0) }
        } else {
            // Legacy class-goals shape: replace only the class-goal subset.
            let newGoals = try (body.goals ?? []).map { try achievement(from: $0) }
            let existing =
                (try? JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8)))?
                .achievements ?? []
            merged = existing.filter { $0.kind != .classGoal } + newGoals
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(merged))
            // A unified save means the instructor curated the full list — the
            // manifest is now authoritative (built-in defaults no longer merge in).
            if isUnified { dict["builtInAchievementsSeeded"] = true }
        }
        return makeAchievementsResponse(fromManifest: setup.manifest)
    }

    // MARK: - Conversions

    private func achievement(from input: ClassGoalInput) throws -> Achievement {
        let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Goal name must not be empty.")
        }
        guard (0...100).contains(input.thresholdPercent),
            (0...100).contains(input.classPercent),
            input.bonusPoints >= 0
        else {
            throw WebAssignmentError.invalidParameter(
                name: "goal",
                reason: "Threshold and class share must be 0–100; bonus points must be ≥ 0.")
        }
        let goalID: String
        if let existing = input.id, !existing.isEmpty {
            goalID = existing
        } else {
            goalID = "goal_\(UUID().uuidString.prefix(8))"
        }
        return Achievement(
            id: goalID,
            name: trimmed,
            kind: .classGoal,
            scope: .classWide,
            reward: AchievementReward(type: .points, label: trimmed, points: input.bonusPoints),
            target: AchievementTarget(kind: .assignmentGrade),
            threshold: input.thresholdPercent / 100,
            classFraction: input.classPercent / 100)
    }

    private func classGoalRows(fromManifest manifest: String) -> [ClassGoalInput] {
        guard let props = try? JSONDecoder().decode(TestProperties.self, from: Data(manifest.utf8))
        else { return [] }
        return props.achievements.filter { $0.kind == .classGoal }.map { a in
            ClassGoalInput(
                id: a.id,
                name: a.name,
                thresholdPercent: (a.threshold ?? 0) * 100,
                classPercent: (a.classFraction ?? 0) * 100,
                bonusPoints: a.reward.points ?? 0)
        }
    }
}
