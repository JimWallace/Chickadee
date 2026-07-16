// Core/AchievementEvaluation.swift
//
// Pure evaluation of the composable `Achievement` model: classifying an
// achievement by its (scope, conditions, reward) shape, and deciding whether a
// submission's signals satisfy its conditions.  Kept Vapor-free and free of any
// database type so it is unit-testable in isolation (mirroring
// `classGoalProgress`) and shareable between every server evaluation site.

/// The graded signals one submission exposes to achievement conditions.  A
/// `nil` field means "not known at this evaluation site" — a condition reading
/// an unknown signal is treated as unmet (it can't be proven satisfied).
public struct AchievementSignals: Sendable {
    public var gradePercent: Int
    public var attemptNumber: Int?
    public var executionTimeMs: Int?
    /// Grade percent of the immediately preceding attempt; nil on the first.
    public var priorGradePercent: Int?
    public var outcomes: [TestOutcome]
    /// Alias map for `testPass` refs: for each outcome `testName` (as stamped
    /// by the runner — display name, else filename stem), every name that
    /// outcome answers to (its script filename, stem, and display name).
    /// Derive it from the manifest via `TestProperties.testNameAliases()`.
    /// Without it, a ref still matches an outcome's `testName` directly or by
    /// its own extension-stripped stem, so filename-authored refs resolve for
    /// scripts that have no display name even at alias-less call sites.
    public var testNameAliases: [String: Set<String>]

    public init(
        gradePercent: Int,
        attemptNumber: Int? = nil,
        executionTimeMs: Int? = nil,
        priorGradePercent: Int? = nil,
        outcomes: [TestOutcome] = [],
        testNameAliases: [String: Set<String>] = [:]
    ) {
        self.gradePercent = gradePercent
        self.attemptNumber = attemptNumber
        self.executionTimeMs = executionTimeMs
        self.priorGradePercent = priorGradePercent
        self.outcomes = outcomes
        self.testNameAliases = testNameAliases
    }
}

extension AchievementCondition {
    /// Whether this single predicate holds for `signals`.
    public func isSatisfied(by signals: AchievementSignals) -> Bool {
        switch signal {
        case .grade:
            return compare(Double(signals.gradePercent))
        case .attempts:
            guard let attempts = signals.attemptNumber else { return false }
            return compare(Double(attempts))
        case .executionTimeMs:
            guard let time = signals.executionTimeMs else { return false }
            return compare(Double(time))
        case .gradeJumpPercent:
            guard let prior = signals.priorGradePercent else { return false }
            return compare(Double(signals.gradePercent - prior))
        case .testPass:
            guard let ref = target?.ref else { return false }
            // Refs are authored as script filenames (the documented contract)
            // but runner outcomes carry the display name, else the filename
            // stem (`runnerOutcomeTestName`) — so match the ref against the
            // outcome name, the ref's own stem, and the manifest-derived
            // aliases (filename / stem / display name) for that outcome.
            return signals.outcomes.contains { outcome in
                guard outcome.status == .pass else { return false }
                if outcome.testName == ref { return true }
                if runnerScriptStem(ref) == outcome.testName { return true }
                return signals.testNameAliases[outcome.testName]?.contains(ref) ?? false
            }
        }
    }

    private func compare(_ lhs: Double) -> Bool {
        switch comparator {
        case .atLeast: return lhs >= value
        case .atMost: return lhs <= value
        case .equals: return lhs == value
        }
    }
}

extension Achievement {

    /// Whether this achievement's conditions hold for `signals`, honouring
    /// `match`.  An achievement with no conditions is vacuously satisfied (a
    /// `record` ranks rather than gates).
    public func isSatisfied(by signals: AchievementSignals) -> Bool {
        guard !conditions.isEmpty else { return true }
        switch match {
        case .all: return conditions.allSatisfy { $0.isSatisfied(by: signals) }
        case .any: return conditions.contains { $0.isSatisfied(by: signals) }
        }
    }

    // MARK: Classification

    /// Reads as a class-by-quantifier collaborative goal: class-wide scope with a
    /// positive points bonus (`classFraction` of the class reaching the goal).
    public var isClassGoal: Bool {
        scope == .classWide && reward.type == .points
    }

    /// A single-holder competitive record (pathfinder / fastest / …).
    public var isClassRecord: Bool {
        scope == .record
    }

    /// True when any condition reads a per-attempt dynamic signal (attempt
    /// count, execution time, grade jump) — the badges historically evaluated at
    /// submission time from the run context (First-Try Perfect, comeback,
    /// persistence, speed).  Distinguishes them from the grade/test badges.
    public var usesDynamicSignal: Bool {
        conditions.contains {
            $0.signal == .attempts || $0.signal == .executionTimeMs
                || $0.signal == .gradeJumpPercent
        }
    }

    /// An individual badge whose condition depends on the run's dynamic signals.
    public var isPerSubmissionBadge: Bool {
        scope == .individual && reward.type == .badge && usesDynamicSignal
    }

    /// An individual badge decided purely by grade and/or a test passing — the
    /// instructor-authorable score / test badges.
    public var isAuthorableIndividualBadge: Bool {
        scope == .individual && reward.type == .badge && !usesDynamicSignal
    }

    /// The grade threshold (as a `0...1` fraction) of this achievement's first
    /// `grade` condition, if any — the metric the class-goal sweep counts
    /// against.  nil when the achievement has no grade condition.
    public var gradeThresholdFraction: Double? {
        conditions.first { $0.signal == .grade }.map { $0.value / 100 }
    }

    /// Whether the class-goal sweep can evaluate this achievement's conditions
    /// as authored.  The sweep counts students by their best whole-assignment
    /// grade, so it supports exactly: no conditions (grade must be 100%), or a
    /// single `grade` condition with the `atLeast` comparator.  Anything richer
    /// (other signals, `atMost`/`equals`, multiple conditions) would be
    /// silently mis-evaluated — authoring rejects those shapes for classWide
    /// scope, and the sweep skips (and logs) any that reach it from a
    /// hand-authored manifest.
    public var isSweepEvaluableClassGoal: Bool {
        guard isClassGoal else { return false }
        if conditions.isEmpty { return true }
        guard conditions.count == 1, let condition = conditions.first else { return false }
        return condition.signal == .grade && condition.comparator == .atLeast
    }
}

extension TestProperties {
    /// Alias map for achievement `testPass` matching: for every suite entry
    /// (hand-written or generated), keys the runner-stamped outcome name
    /// (`runnerOutcomeTestName` — display name, else filename stem) to the full
    /// set of names that entry answers to: its script filename, the filename's
    /// stem, and its display name.  Feed to `AchievementSignals` so a ref
    /// authored as any of those forms resolves against real runner outcomes.
    public func testNameAliases() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for entry in testSuites {
            let outcomeName = runnerOutcomeTestName(displayName: entry.name, script: entry.script)
            var names: Set<String> = [entry.script, runnerScriptStem(entry.script), outcomeName]
            if let display = entry.name { names.insert(display) }
            map[outcomeName, default: []].formUnion(names)
        }
        return map
    }

    /// Every name a `testPass` ref may legally use for this suite — the union
    /// of `testNameAliases()` values.  Used by author-time validation.
    public var allTestRefNames: Set<String> {
        testNameAliases().values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}
