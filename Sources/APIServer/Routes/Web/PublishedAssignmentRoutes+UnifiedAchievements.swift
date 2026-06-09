// APIServer/Routes/Web/PublishedAssignmentRoutes+UnifiedAchievements.swift
//
// Unification B — the typed, all-kinds achievement row used by the single
// "Achievements" editor table.  `AchievementInput` is a flat, editor-friendly
// projection of `Achievement`: one row per achievement of any kind, with the
// kind-specific parameters as optional fields.  `achievement(fromUnified:)`
// validates + converts a row to the domain model; `achievementInput(from:)` is
// the reverse for GET.  The PUT/GET handlers live in
// `PublishedAssignmentRoutes+Achievements.swift`.

import Core
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    /// One row in the unified Achievements table — any kind.
    struct AchievementInput: Content {
        var id: String?
        var name: String
        /// Raw `AchievementKind` value (classGoal / thresholdBadge / testBadge /
        /// firstTryPerfect / comeback / persistence / speedRun / classRecord).
        var kind: String
        var detail: String?
        /// Grade cutoff %, 0–100 (classGoal + thresholdBadge target, and the
        /// grade gate for firstTryPerfect / persistence / speedRun).
        var thresholdPercent: Double?
        /// classGoal: share of the class, 0–100.
        var classPercent: Double?
        /// classGoal: positive bonus points.
        var points: Int?
        /// testBadge: the test filename that must pass.
        var testName: String?
        /// classRecord: raw `RecordDimension`.
        var recordDimension: String?
        /// firstTryPerfect (max) / persistence (min) attempt cutoff.
        var attemptThreshold: Int?
        /// speedRun: total-execution cutoff in ms.
        var timeThresholdMs: Int?
        /// comeback: minimum grade jump in percentage points.
        var jumpThresholdPercent: Int?
    }

    func achievement(fromUnified input: AchievementInput) throws -> Achievement {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Name must not be empty.")
        }
        guard let kind = AchievementKind(rawValue: input.kind) else {
            throw WebAssignmentError.invalidParameter(
                name: "kind", reason: "Unknown achievement kind '\(input.kind)'.")
        }
        let id = unifiedAchievementID(input.id)
        let detail = input.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetail = (detail?.isEmpty == false) ? detail : nil

        switch kind {
        case .classGoal:
            return try classGoalAchievement(input, id: id, name: name, detail: cleanDetail)
        case .thresholdBadge:
            return Achievement(
                id: id, name: name, detail: cleanDetail, kind: .thresholdBadge, scope: .individual,
                reward: AchievementReward(type: .badge, label: name),
                target: AchievementTarget(kind: .assignmentGrade),
                threshold: try gradeFraction(input.thresholdPercent, fallback: 0.9))
        case .testBadge:
            let test = (input.testName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !test.isEmpty else {
                throw WebAssignmentError.invalidParameter(
                    name: "testName", reason: "A test badge needs the filename of the test that must pass.")
            }
            return Achievement(
                id: id, name: name, detail: cleanDetail, kind: .testBadge, scope: .individual,
                reward: AchievementReward(type: .badge, label: name),
                target: AchievementTarget(kind: .testPass, ref: test))
        case .firstTryPerfect, .persistence:
            return Achievement(
                id: id, name: name, detail: cleanDetail, kind: kind, scope: .individual,
                reward: AchievementReward(type: .badge, label: name),
                target: AchievementTarget(kind: .assignmentGrade),
                threshold: try gradeFraction(input.thresholdPercent, fallback: 1.0),
                attemptThreshold: input.attemptThreshold ?? (kind == .firstTryPerfect ? 1 : 5))
        case .comeback:
            return Achievement(
                id: id, name: name, detail: cleanDetail, kind: .comeback, scope: .individual,
                reward: AchievementReward(type: .badge, label: name),
                target: AchievementTarget(kind: .assignmentGrade),
                jumpThresholdPercent: input.jumpThresholdPercent ?? 50)
        case .speedRun:
            return Achievement(
                id: id, name: name, detail: cleanDetail, kind: .speedRun, scope: .individual,
                reward: AchievementReward(type: .badge, label: name),
                target: AchievementTarget(kind: .assignmentGrade),
                threshold: try gradeFraction(input.thresholdPercent, fallback: 1.0),
                timeThresholdMs: input.timeThresholdMs ?? 2_000)
        case .classRecord:
            guard let dim = RecordDimension(rawValue: input.recordDimension ?? "firstToSolve") else {
                throw WebAssignmentError.invalidParameter(
                    name: "recordDimension", reason: "Unknown record dimension '\(input.recordDimension ?? "")'.")
            }
            return Achievement(
                id: id, name: name, detail: cleanDetail, kind: .classRecord, scope: .classWide,
                reward: AchievementReward(type: .title, label: name), recordDimension: dim)
        }
    }

    private func classGoalAchievement(
        _ input: AchievementInput, id: String, name: String, detail: String?
    ) throws -> Achievement {
        guard let classPercent = input.classPercent, (0...100).contains(classPercent) else {
            throw WebAssignmentError.invalidParameter(
                name: "classPercent", reason: "Class share must be 0–100.")
        }
        let points = input.points ?? 0
        guard points >= 0 else {
            throw WebAssignmentError.invalidParameter(name: "points", reason: "Bonus points must be ≥ 0.")
        }
        return Achievement(
            id: id, name: name, detail: detail, kind: .classGoal, scope: .classWide,
            reward: AchievementReward(type: .points, label: name, points: points),
            target: AchievementTarget(kind: .assignmentGrade),
            threshold: try gradeFraction(input.thresholdPercent, fallback: 0),
            classFraction: classPercent / 100)
    }

    /// Validates a 0–100 grade % and returns the 0…1 fraction; `fallback` (a
    /// fraction) is used when the field is absent.
    private func gradeFraction(_ percent: Double?, fallback: Double) throws -> Double {
        let pct = percent ?? (fallback * 100)
        guard (0...100).contains(pct) else {
            throw WebAssignmentError.invalidParameter(
                name: "thresholdPercent", reason: "Grade threshold must be 0–100.")
        }
        return pct / 100
    }

    private func unifiedAchievementID(_ id: String?) -> String {
        if let id, !id.isEmpty { return id }
        return "ach_\(UUID().uuidString.prefix(8))"
    }

    func achievementInput(from a: Achievement) -> AchievementInput {
        AchievementInput(
            id: a.id, name: a.name, kind: a.kind.rawValue, detail: a.detail,
            thresholdPercent: a.threshold.map { $0 * 100 },
            classPercent: a.classFraction.map { $0 * 100 },
            points: a.reward.points,
            testName: a.target.kind == .testPass ? a.target.ref : nil,
            recordDimension: a.recordDimension?.rawValue,
            attemptThreshold: a.attemptThreshold,
            timeThresholdMs: a.timeThresholdMs,
            jumpThresholdPercent: a.jumpThresholdPercent)
    }

    func unifiedAchievementRows(fromManifest manifest: String) -> [AchievementInput] {
        guard let props = try? JSONDecoder().decode(TestProperties.self, from: Data(manifest.utf8))
        else { return [] }
        return props.achievements.map(achievementInput(from:))
    }
}
