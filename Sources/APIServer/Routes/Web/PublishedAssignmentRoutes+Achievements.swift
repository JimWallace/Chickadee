// APIServer/Routes/Web/PublishedAssignmentRoutes+Achievements.swift
//
// Instructor authoring for the composable Achievements editor.
//
// GET returns one editable row per achievement; PUT replaces the manifest's
// `achievements` array wholesale.  `AchievementInput` is the editor-facing
// projection of `Achievement`: a scope, a list of typed conditions combined
// with `match`, and the scope's reward parameters (class share + points for a
// class goal, ranking dimension for a record).  Achievements are
// server-evaluated and display-only — they never change what the suite grades —
// so, unlike suite edits, this path does NOT retest submissions, reschedule
// validation, or close the assignment.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    /// One condition row in the editor: a signal compared against a value, with
    /// an optional test filename for `testPass`.
    struct ConditionInput: Content {
        var signal: String  // grade | attempts | executionTimeMs | gradeJumpPercent | testPass
        var comparator: String  // atLeast | atMost | equals
        var value: Double?
        /// `testPass`: the test filename that must pass.
        var testRef: String?
    }

    /// One row in the composable Achievements table.
    struct AchievementInput: Content {
        var id: String?
        var name: String
        var detail: String?
        /// Raw `AchievementScope` value: individual / classWide / record.
        var scope: String
        /// Raw `ConditionMatch` value: all / any (default all).
        var match: String?
        var conditions: [ConditionInput]?
        /// classWide: share of the class that must satisfy the conditions, 0–100.
        var classPercent: Double?
        /// classWide: positive bonus points awarded when the goal is met.
        var points: Int?
        /// record: raw `RecordDimension`.
        var recordDimension: String?
    }

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
        return AchievementsResponse(achievements: unifiedAchievementRows(fromManifest: setup.manifest))
    }

    // MARK: - PUT /instructor/:assignmentID/achievements

    @Sendable
    func putAchievements(req: Request) async throws -> AchievementsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(AchievementsBody.self)
        let achievements = try body.achievements.map { try achievement(fromUnified: $0) }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(achievements))
            // Saving the table means the instructor curated the full list — the
            // manifest is now authoritative (built-in defaults no longer merge in).
            dict["builtInAchievementsSeeded"] = true
        }
        return AchievementsResponse(achievements: unifiedAchievementRows(fromManifest: setup.manifest))
    }

    // MARK: - Row → domain

    func achievement(fromUnified input: AchievementInput) throws -> Achievement {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Name must not be empty.")
        }
        guard let scope = AchievementScope(rawValue: input.scope) else {
            throw WebAssignmentError.invalidParameter(
                name: "scope", reason: "Unknown scope '\(input.scope)'.")
        }
        let id = unifiedAchievementID(input.id)
        let detail = input.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetail = (detail?.isEmpty == false) ? detail : nil
        let match = ConditionMatch(rawValue: input.match ?? "all") ?? .all
        let conditions = try (input.conditions ?? []).map(condition(fromInput:))

        switch scope {
        case .individual:
            return Achievement(
                id: id, name: name, detail: cleanDetail, scope: .individual,
                conditions: conditions, match: match,
                reward: AchievementReward(type: .badge, label: name))
        case .classWide:
            guard let classPercent = input.classPercent, (0...100).contains(classPercent) else {
                throw WebAssignmentError.invalidParameter(
                    name: "classPercent", reason: "Class share must be 0–100.")
            }
            let points = input.points ?? 0
            guard points >= 0 else {
                throw WebAssignmentError.invalidParameter(
                    name: "points", reason: "Bonus points must be ≥ 0.")
            }
            return Achievement(
                id: id, name: name, detail: cleanDetail, scope: .classWide,
                conditions: conditions, match: match,
                reward: AchievementReward(type: .points, label: name, points: points),
                classFraction: classPercent / 100)
        case .record:
            guard let dim = RecordDimension(rawValue: input.recordDimension ?? "firstToSolve") else {
                throw WebAssignmentError.invalidParameter(
                    name: "recordDimension",
                    reason: "Unknown record dimension '\(input.recordDimension ?? "")'.")
            }
            return Achievement(
                id: id, name: name, detail: cleanDetail, scope: .record,
                reward: AchievementReward(type: .title, label: name),
                recordDimension: dim)
        }
    }

    private func condition(fromInput input: ConditionInput) throws -> AchievementCondition {
        guard let signal = AchievementSignal(rawValue: input.signal) else {
            throw WebAssignmentError.invalidParameter(
                name: "signal", reason: "Unknown condition signal '\(input.signal)'.")
        }
        guard let comparator = ConditionComparator(rawValue: input.comparator) else {
            throw WebAssignmentError.invalidParameter(
                name: "comparator", reason: "Unknown comparator '\(input.comparator)'.")
        }
        if signal == .testPass {
            let ref = (input.testRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ref.isEmpty else {
                throw WebAssignmentError.invalidParameter(
                    name: "testRef", reason: "A 'test passes' condition needs a test filename.")
            }
            return AchievementCondition(
                signal: .testPass, comparator: .atLeast, value: 1,
                target: AchievementTarget(kind: .testPass, ref: ref))
        }
        let value = input.value ?? 0
        if signal == .grade || signal == .gradeJumpPercent {
            guard (0...100).contains(value) else {
                throw WebAssignmentError.invalidParameter(
                    name: "value", reason: "A percent value must be 0–100.")
            }
        } else if value < 0 {
            throw WebAssignmentError.invalidParameter(
                name: "value", reason: "Value must not be negative.")
        }
        return AchievementCondition(signal: signal, comparator: comparator, value: value)
    }

    private func unifiedAchievementID(_ id: String?) -> String {
        if let id, !id.isEmpty { return id }
        return "ach_\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Domain → row

    func achievementInput(from a: Achievement) -> AchievementInput {
        AchievementInput(
            id: a.id,
            name: a.name,
            detail: a.detail,
            scope: a.scope.rawValue,
            match: a.match.rawValue,
            conditions: a.conditions.map(conditionInput(from:)),
            classPercent: a.classFraction.map { $0 * 100 },
            points: a.reward.points,
            recordDimension: a.recordDimension?.rawValue)
    }

    private func conditionInput(from c: AchievementCondition) -> ConditionInput {
        ConditionInput(
            signal: c.signal.rawValue,
            comparator: c.comparator.rawValue,
            value: c.value,
            testRef: c.signal == .testPass ? c.target?.ref : nil)
    }

    /// The rows shown in the editor table.  Until the instructor first saves the
    /// table (`builtInAchievementsSeeded`), the built-in defaults the manifest
    /// hasn't authored yet are merged in so they appear as editable rows; after
    /// seeding, the manifest is authoritative (a removed built-in stays removed).
    func unifiedAchievementRows(fromManifest manifest: String) -> [AchievementInput] {
        guard let props = try? JSONDecoder().decode(TestProperties.self, from: Data(manifest.utf8))
        else { return BuiltInAchievements.all.map(achievementInput(from:)) }
        let authored = props.achievements
        guard !props.builtInAchievementsSeeded else {
            return authored.map(achievementInput(from:))
        }
        let authoredIDs = Set(authored.map(\.id))
        let defaults = BuiltInAchievements.all.filter { !authoredIDs.contains($0.id) }
        return (authored + defaults).map(achievementInput(from:))
    }
}
