// APIServer/Services/AchievementsEditingService.swift
//
// Shared core for authoring an assignment's composable Achievements list,
// used by both the web editor (`PUT /instructor/:id/achievements`) and the
// MCP get/update tools so both speak one row shape and run one validator.
//
// `AchievementRow` is the editor-facing projection of `Achievement`: a scope, a
// list of typed conditions combined with `match`, and the scope's reward
// parameters (class share + points for a class goal, ranking dimension for a
// record). `AchievementsEditing` owns the row <-> domain conversion (with the
// same validation the web editor always ran) plus the manifest read/write.
//
// Achievements are server-evaluated and display-only — they never change what
// the suite grades — so, unlike suite edits, `apply` does NOT retest
// submissions, reschedule validation, or close the assignment.

import Core
import Fluent
import Foundation

/// One condition row in the editor: a signal compared against a value, with an
/// optional test filename for `testPass`.
struct ConditionRow: Codable, Sendable {
    var signal: String  // grade | attempts | executionTimeMs | gradeJumpPercent | testPass
    var comparator: String  // atLeast | atMost | equals
    var value: Double?
    /// `testPass`: the test filename that must pass.
    var testRef: String?

    init(signal: String, comparator: String, value: Double? = nil, testRef: String? = nil) {
        self.signal = signal
        self.comparator = comparator
        self.value = value
        self.testRef = testRef
    }
}

/// One row in the composable Achievements table.
struct AchievementRow: Codable, Sendable {
    var id: String?
    var name: String
    var detail: String?
    /// Raw `AchievementScope` value: individual / classWide / record.
    var scope: String
    /// Raw `ConditionMatch` value: all / any (default all).
    var match: String?
    var conditions: [ConditionRow]?
    /// classWide: share of the class that must satisfy the conditions, 0–100.
    var classPercent: Double?
    /// classWide: positive bonus points awarded when the goal is met.
    var points: Int?
    /// record: raw `RecordDimension`.
    var recordDimension: String?

    init(
        id: String? = nil,
        name: String,
        detail: String? = nil,
        scope: String,
        match: String? = nil,
        conditions: [ConditionRow]? = nil,
        classPercent: Double? = nil,
        points: Int? = nil,
        recordDimension: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.scope = scope
        self.match = match
        self.conditions = conditions
        self.classPercent = classPercent
        self.points = points
        self.recordDimension = recordDimension
    }
}

/// Conversion + persistence for the composable Achievements list.
enum AchievementsEditing {

    // MARK: - Row → domain

    /// Validates one editor row and projects it into the domain `Achievement`.
    /// Throws `WebAssignmentError.invalidParameter` for bad input.
    static func achievement(from input: AchievementRow) throws -> Achievement {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Name must not be empty.")
        }
        guard let scope = AchievementScope(rawValue: input.scope) else {
            throw WebAssignmentError.invalidParameter(
                name: "scope", reason: "Unknown scope '\(input.scope)'.")
        }
        let id = newID(input.id)
        let detail = input.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetail = (detail?.isEmpty == false) ? detail : nil
        let match = ConditionMatch(rawValue: input.match ?? "all") ?? .all
        let conditions = try (input.conditions ?? []).map(condition(from:))

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
            let goal = Achievement(
                id: id, name: name, detail: cleanDetail, scope: .classWide,
                conditions: conditions, match: match,
                reward: AchievementReward(type: .points, label: name, points: points),
                classFraction: classPercent / 100)
            // The class-goal sweep counts students by their best
            // whole-assignment grade, so only the shapes it can evaluate are
            // authorable: no conditions (= everyone must reach 100%) or a
            // single "grade at least X" condition.  Richer goals used to save
            // fine and then be silently mis-evaluated as grade-only (audit A4).
            guard goal.isSweepEvaluableClassGoal else {
                throw WebAssignmentError.invalidParameter(
                    name: "conditions",
                    reason: "A class goal currently supports at most one condition, and it must be "
                        + "'grade at least X%'. Attempts/time/test conditions and atMost/equals "
                        + "comparators aren't evaluated for class goals yet.")
            }
            return goal
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

    private static func condition(from input: ConditionRow) throws -> AchievementCondition {
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

    private static func newID(_ id: String?) -> String {
        if let id, !id.isEmpty { return id }
        return "ach_\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Domain → row

    static func row(from a: Achievement) -> AchievementRow {
        AchievementRow(
            id: a.id,
            name: a.name,
            detail: a.detail,
            scope: a.scope.rawValue,
            match: a.match.rawValue,
            conditions: a.conditions.map(conditionRow(from:)),
            classPercent: a.classFraction.map { $0 * 100 },
            points: a.reward.points,
            recordDimension: a.recordDimension?.rawValue)
    }

    private static func conditionRow(from c: AchievementCondition) -> ConditionRow {
        ConditionRow(
            signal: c.signal.rawValue,
            comparator: c.comparator.rawValue,
            value: c.value,
            testRef: c.signal == .testPass ? c.target?.ref : nil)
    }

    // MARK: - Manifest read/write

    /// The rows shown in the editor table.  Until the instructor first saves the
    /// table (`builtInAchievementsSeeded`), the built-in defaults the manifest
    /// hasn't authored yet are merged in so they appear as editable rows; after
    /// seeding, the manifest is authoritative (a removed built-in stays removed).
    static func rows(fromManifest manifest: String) -> [AchievementRow] {
        guard let props = try? JSONDecoder().decode(TestProperties.self, from: Data(manifest.utf8))
        else { return BuiltInAchievements.all.map(row(from:)) }
        let authored = props.achievements
        guard !props.builtInAchievementsSeeded else {
            return authored.map(row(from:))
        }
        let authoredIDs = Set(authored.map(\.id))
        let defaults = BuiltInAchievements.all.filter { !authoredIDs.contains($0.id) }
        return (authored + defaults).map(row(from:))
    }

    /// Replaces the manifest's `achievements` array wholesale with these rows
    /// (validating each via `achievement(from:)`) and marks the built-in
    /// defaults as seeded so they no longer merge into the editable list.
    /// Returns the reconciled rows.  Display-only: does NOT retest, re-validate,
    /// or close the assignment.
    @discardableResult
    static func apply(
        rows: [AchievementRow], setup: APITestSetup, on db: Database
    ) async throws -> [AchievementRow] {
        let achievements = try rows.map { try achievement(from: $0) }
        try validate(achievements, againstManifest: setup.manifest)
        try await mutateManifest(setup: setup, on: db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(achievements))
            // Saving the table means the instructor curated the full list — the
            // manifest is now authoritative (built-in defaults no longer merge in).
            dict["builtInAchievementsSeeded"] = true
        }
        return Self.rows(fromManifest: setup.manifest)
    }

    /// Cross-row validation the per-row converter can't do: ids must be unique
    /// (duplicates collapse into one snapshot in the class-goal sweep), and
    /// every `testPass` ref must resolve to a test actually in the suite —
    /// by script filename, filename stem, or display name (audit A1/A17; a
    /// typo'd or stale ref used to save fine and then silently never fire).
    static func validate(_ achievements: [Achievement], againstManifest manifest: String) throws {
        var seen = Set<String>()
        for achievement in achievements {
            guard seen.insert(achievement.id).inserted else {
                throw WebAssignmentError.invalidParameter(
                    name: "id", reason: "Duplicate achievement id '\(achievement.id)'.")
            }
        }
        // A malformed manifest can't provide a suite to check against; the
        // rest of the achievements pipeline already treats that as "no suite
        // knowledge", so skip ref validation rather than block the save.
        guard
            let props = try? JSONDecoder().decode(
                TestProperties.self, from: Data(manifest.utf8))
        else { return }
        let validRefs = props.allTestRefNames
        for achievement in achievements {
            for condition in achievement.conditions where condition.signal == .testPass {
                guard let ref = condition.target?.ref, validRefs.contains(ref) else {
                    let ref = condition.target?.ref ?? ""
                    throw WebAssignmentError.invalidParameter(
                        name: "testRef",
                        reason: "'\(ref)' doesn't match any test in this suite. "
                            + "Use the test's script filename (e.g. secrettest_x.py) "
                            + "or its display name.")
                }
            }
        }
    }
}
