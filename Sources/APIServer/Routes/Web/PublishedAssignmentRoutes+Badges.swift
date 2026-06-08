// APIServer/Routes/Web/PublishedAssignmentRoutes+Badges.swift
//
// Instructor authoring for individual badges — the per-student form of an
// Achievement (`thresholdBadge` = "score ≥ X%", `testBadge` = "this test
// passes").  Symmetric to the class-goals endpoint: GET returns the assignment's
// badges as editable rows; PUT replaces the authorable-badge subset of the
// manifest's `achievements` array, preserving class goals and anything else.
// Badges are cosmetic + display-only, so this never retests or re-validates.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    /// One editable individual-badge row from the editor.
    struct BadgeInput: Content {
        var id: String?
        /// Badge caption shown to the student, e.g. "Sharpshooter".
        var name: String
        /// "thresholdBadge" | "testBadge".
        var kind: String
        /// Optional emoji, e.g. "🌟".
        var icon: String?
        /// `thresholdBadge`: the grade cutoff, 0–100.
        var thresholdPercent: Double?
        /// `testBadge`: the script filename that must pass.
        var testName: String?
    }

    struct BadgesBody: Content {
        var badges: [BadgeInput]
    }

    struct BadgesResponse: Content {
        var badges: [BadgeInput]
    }

    // MARK: - GET /instructor/:assignmentID/badges

    @Sendable
    func getBadges(req: Request) async throws -> BadgesResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        return BadgesResponse(badges: badgeRows(fromManifest: setup.manifest))
    }

    // MARK: - PUT /instructor/:assignmentID/badges

    @Sendable
    func putBadges(req: Request) async throws -> BadgesResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(BadgesBody.self)
        let newBadges = try body.badges.map { try achievement(fromBadge: $0) }

        let existing =
            (try? JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8)))?
            .achievements ?? []
        let merged = existing.filter { !isAuthorableIndividualBadge($0) } + newBadges

        try await mutateManifest(setup: setup, on: req.db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(merged))
        }
        return BadgesResponse(badges: badgeRows(fromManifest: setup.manifest))
    }

    // MARK: - Conversions

    private func achievement(fromBadge input: BadgeInput) throws -> Achievement {
        let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Badge name must not be empty.")
        }
        let badgeID: String
        if let existing = input.id, !existing.isEmpty {
            badgeID = existing
        } else {
            badgeID = "badge_\(UUID().uuidString.prefix(8))"
        }
        let trimmedIcon = input.icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reward = AchievementReward(
            type: .badge, label: trimmed,
            icon: (trimmedIcon?.isEmpty == false) ? trimmedIcon : nil)

        switch input.kind {
        case "thresholdBadge":
            guard let pct = input.thresholdPercent, (0...100).contains(pct) else {
                throw WebAssignmentError.invalidParameter(
                    name: "thresholdPercent", reason: "Score threshold must be 0–100.")
            }
            return Achievement(
                id: badgeID, name: trimmed, kind: .thresholdBadge, scope: .individual,
                reward: reward, target: AchievementTarget(kind: .assignmentGrade),
                threshold: pct / 100)
        case "testBadge":
            let test = (input.testName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !test.isEmpty else {
                throw WebAssignmentError.invalidParameter(
                    name: "testName",
                    reason: "Test-badge rows need the filename of the test that must pass.")
            }
            return Achievement(
                id: badgeID, name: trimmed, kind: .testBadge, scope: .individual,
                reward: reward, target: AchievementTarget(kind: .testPass, ref: test))
        default:
            throw WebAssignmentError.invalidParameter(
                name: "kind", reason: "Unknown badge kind '\(input.kind)'.")
        }
    }

    private func badgeRows(fromManifest manifest: String) -> [BadgeInput] {
        guard let props = try? JSONDecoder().decode(TestProperties.self, from: Data(manifest.utf8))
        else { return [] }
        return props.achievements.filter(isAuthorableIndividualBadge).map { a in
            BadgeInput(
                id: a.id, name: a.reward.label, kind: a.kind.rawValue, icon: a.reward.icon,
                thresholdPercent: a.threshold.map { $0 * 100 },
                testName: a.target.ref)
        }
    }
}
