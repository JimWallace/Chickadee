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
        case .itemsCovered:
            // Not a per-submission signal: it reads the class's accumulated
            // coverage, which no single submission's signals can answer.  The
            // convention for an unknown signal applies — unmet, because it
            // cannot be proven satisfied here.  The class-goal sweep is the
            // only evaluator that can read it (`classUnionGoalProgress`), and
            // `isSweepEvaluableClassGoal` is what keeps it out of every other
            // shape.
            return false
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

    /// A class goal graded on the UNION of what the class produced rather than
    /// on a count of students clearing a grade threshold — the collaborative
    /// "the class has found 12 of the seeded bugs" shape.
    ///
    /// The two kinds of class goal are mutually exclusive by construction: the
    /// sweep admits exactly one condition, so a goal is either grade-counted or
    /// union-counted and never both.
    public var isUnionClassGoal: Bool {
        isClassGoal && conditions.contains { $0.signal == .itemsCovered }
    }

    /// How many distinct items a union class goal requires the class to cover,
    /// and which suite items count toward it.  nil when this is not a union
    /// goal.
    ///
    /// A nil `scope` means "every item in the suite"; a `.section` scope counts
    /// only that suite section's items, which is how a bug hunt's variants are
    /// separated from the "your test is well-formed" gate test beside them.
    public var coveredItemsRequirement: (count: Int, scope: AchievementTarget?)? {
        guard isUnionClassGoal,
            let condition = conditions.first(where: { $0.signal == .itemsCovered })
        else { return nil }
        return (max(0, Int(condition.value)), condition.target)
    }

    /// Whether the class-goal sweep can evaluate this achievement's conditions
    /// as authored.  It supports exactly three shapes:
    ///
    /// - no conditions — every student must reach 100%;
    /// - a single `grade atLeast` condition — counted over students' best
    ///   whole-assignment grades;
    /// - a single `itemsCovered atLeast` condition — counted over the class's
    ///   accumulated coverage union, with `classFraction` reinterpreted as the
    ///   share of the roster that must have contributed a credited item.
    ///
    /// Anything richer (other signals, `atMost`/`equals`, multiple conditions)
    /// would be silently mis-evaluated — authoring rejects those shapes for
    /// classWide scope, and the sweep skips (and logs) any that reach it from a
    /// hand-authored manifest.  Keeping this closed is the reason a
    /// hand-authored manifest cannot quietly mis-grade a bonus (audit A4), so
    /// admitting the union shape means admitting exactly it, not relaxing the
    /// arity.
    public var isSweepEvaluableClassGoal: Bool {
        guard isClassGoal else { return false }
        if conditions.isEmpty { return true }
        guard conditions.count == 1, let condition = conditions.first else { return false }
        guard condition.comparator == .atLeast else { return false }
        switch condition.signal {
        case .grade:
            return true
        case .itemsCovered:
            // A `.section` scope must name the section; `.suiteItem`,
            // `.testPass` and `.assignmentGrade` scope nothing a union can be
            // taken over.
            switch condition.target?.kind {
            case .none, .some(.section):
                return condition.target == nil || condition.target?.ref?.isEmpty == false
            case .some(.assignmentGrade), .some(.suiteItem), .some(.testPass):
                return false
            }
        case .attempts, .executionTimeMs, .gradeJumpPercent, .testPass:
            return false
        }
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

    /// The runner-stamped item names a union class goal counts, given the
    /// condition's optional scope.
    ///
    /// nil scope = every suite item.  A `.section` scope = only that section's
    /// items, which is what separates a bug hunt's seeded variants from the
    /// well-formedness gate test sitting beside them in the same suite.
    ///
    /// Names are `runnerOutcomeTestName` — the same form
    /// `recordClassItemCoverage` stores — so the caller can intersect the
    /// coverage rows against this set directly.
    public func coveredItemNames(inScopeOf scope: AchievementTarget?) -> Set<String> {
        let entries: [TestSuiteEntry]
        switch scope?.kind {
        case .some(.section):
            guard let ref = scope?.ref else { return [] }
            entries = testSuites.filter { $0.sectionID == ref }
        case .none:
            entries = testSuites
        case .some(.assignmentGrade), .some(.suiteItem), .some(.testPass):
            // Not a set of items; `isSweepEvaluableClassGoal` refuses these
            // shapes, so reaching here means a manifest the sweep skips.
            return []
        }
        return Set(entries.map { runnerOutcomeTestName(displayName: $0.name, script: $0.script) })
    }
}
