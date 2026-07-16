// Core/Achievement.swift

/// An instructor-authored reward attached to one assignment — the generalized,
/// per-assignment form of Chickadee's previously-hardcoded badge and
/// class-achievement system.
///
/// Achievements are **server-evaluated and display-only**: they never run as a
/// per-submission test, and `TestProperties.runnerSanitized()` strips them from
/// the runner-facing manifest so a runner never has to decode an achievement
/// shape it doesn't know (the same rationale as `patternFamilies` /
/// `notebookChecks`).
///
/// ## The composable model (v0.4.x redesign)
///
/// An achievement is a **design space**, not one of a fixed menu of kinds.  It
/// is the combination of three independent choices:
///
/// - a `scope` — earned per-student (`individual`), computed across the class
///   (`classWide`, a collaborative goal), or a single-holder competitive
///   `record`;
/// - a list of `conditions` — typed predicates over a submission's graded
///   signals (grade, attempt count, execution time, grade jump, a test passing),
///   combined with `match` (`all` = AND / `any` = OR);
/// - a `reward` — a cosmetic badge, a one-holder title, or a positive points
///   bonus.
///
/// This subsumes every award the old closed `AchievementKind` enum expressed
/// (First-Try Perfect, comeback, persistence, speed, score/test badges, the
/// collaborative class goal, and the pathfinder / speed-champion / minimalist
/// records) while letting an instructor combine signals freely — e.g. "100% in
/// ≤2 attempts *and* under 1.5 s".  Legacy manifests authored against the old
/// enum decode transparently (`init(from:)` maps the old `kind` + flat fields
/// into `conditions`); re-saving migrates them forward to the new shape.
public struct Achievement: Codable, Equatable, Sendable {
    public let id: String
    /// Student-facing label, e.g. "Class Goal: 80% reach mastery".
    public let name: String
    /// Optional longer description shown to students ("how to earn this").
    public let detail: String?
    /// Earned per-student, computed across the class, or a single-holder record.
    public let scope: AchievementScope
    /// The typed predicates a submission must satisfy.  Empty conditions are
    /// vacuously satisfied (the `record` scope ranks rather than gates, so its
    /// conditions are usually empty).
    public let conditions: [AchievementCondition]
    /// Whether all conditions (AND) or any condition (OR) must hold.
    public let match: ConditionMatch
    /// What a student gets for earning it.
    public let reward: AchievementReward
    /// Proportion of the class (`0...1`) that must satisfy `conditions` for a
    /// `classWide` goal to be fully met.  nil for other scopes.
    public let classFraction: Double?
    /// Which dimension a `record` ranks students on.  nil for other scopes.
    public let recordDimension: RecordDimension?
    /// Suite section this achievement renders under; nil = the trailing
    /// "Achievements" block.
    public let sectionID: String?

    public init(
        id: String,
        name: String,
        detail: String? = nil,
        scope: AchievementScope,
        conditions: [AchievementCondition] = [],
        match: ConditionMatch = .all,
        reward: AchievementReward,
        classFraction: Double? = nil,
        recordDimension: RecordDimension? = nil,
        sectionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.scope = scope
        self.conditions = conditions
        self.match = match
        self.reward = reward
        self.classFraction = classFraction
        self.recordDimension = recordDimension
        self.sectionID = sectionID
    }

    // MARK: Codable (new shape out; new-or-legacy in)

    enum CodingKeys: String, CodingKey {
        case id, name, detail, scope, conditions, match, reward, classFraction
        case recordDimension, sectionID
        // Legacy keys (decode-only; never written).
        case kind, threshold, target, attemptThreshold, timeThresholdMs, jumpThresholdPercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        reward = try c.decode(AchievementReward.self, forKey: .reward)
        classFraction = try c.decodeIfPresent(Double.self, forKey: .classFraction)
        sectionID = try c.decodeIfPresent(String.self, forKey: .sectionID)

        // A `conditions` key marks the new shape; otherwise this is a manifest
        // authored against the old `kind` enum, which we project into conditions.
        if c.contains(.conditions) {
            scope = try c.decode(AchievementScope.self, forKey: .scope)
            conditions = try c.decode([AchievementCondition].self, forKey: .conditions)
            match = try c.decodeIfPresent(ConditionMatch.self, forKey: .match) ?? .all
            recordDimension = try c.decodeIfPresent(RecordDimension.self, forKey: .recordDimension)
        } else {
            let legacy = try Achievement.legacyProjection(from: c)
            scope = legacy.scope
            conditions = legacy.conditions
            match = .all
            recordDimension = legacy.recordDimension
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(scope, forKey: .scope)
        try c.encode(conditions, forKey: .conditions)
        try c.encode(match, forKey: .match)
        try c.encode(reward, forKey: .reward)
        try c.encodeIfPresent(classFraction, forKey: .classFraction)
        try c.encodeIfPresent(recordDimension, forKey: .recordDimension)
        try c.encodeIfPresent(sectionID, forKey: .sectionID)
    }

    /// Projects a legacy (`kind` + flat-field) achievement into the composable
    /// `(scope, conditions, recordDimension)` shape.  The inverse of how the old
    /// editor built each kind, so existing manifests evaluate identically.
    private static func legacyProjection(
        from c: KeyedDecodingContainer<CodingKeys>
    ) throws -> (scope: AchievementScope, conditions: [AchievementCondition], recordDimension: RecordDimension?) {
        let kind = LegacyAchievementKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "")
        let gradePct = (try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 1) * 100
        let target = try c.decodeIfPresent(AchievementTarget.self, forKey: .target)
        let attempts = try c.decodeIfPresent(Int.self, forKey: .attemptThreshold)
        let timeMs = try c.decodeIfPresent(Int.self, forKey: .timeThresholdMs)
        let jump = try c.decodeIfPresent(Int.self, forKey: .jumpThresholdPercent)
        let dimension = try c.decodeIfPresent(RecordDimension.self, forKey: .recordDimension)

        func grade(_ pct: Double) -> AchievementCondition {
            AchievementCondition(signal: .grade, comparator: .atLeast, value: pct)
        }
        switch kind {
        case .classGoal:
            return (.classWide, [grade(gradePct)], nil)
        case .thresholdBadge:
            return (.individual, [grade(gradePct)], nil)
        case .testBadge:
            return (
                .individual,
                [
                    AchievementCondition(
                        signal: .testPass, comparator: .atLeast, value: 1,
                        target: AchievementTarget(kind: .testPass, ref: target?.ref))
                ], nil
            )
        case .firstTryPerfect:
            return (
                .individual,
                [
                    grade(gradePct),
                    AchievementCondition(
                        signal: .attempts, comparator: .atMost, value: Double(attempts ?? 1)),
                ], nil
            )
        case .persistence:
            return (
                .individual,
                [
                    grade(gradePct),
                    AchievementCondition(
                        signal: .attempts, comparator: .atLeast, value: Double(attempts ?? 5)),
                ], nil
            )
        case .comeback:
            return (
                .individual,
                [
                    AchievementCondition(
                        signal: .gradeJumpPercent, comparator: .atLeast, value: Double(jump ?? 50))
                ], nil
            )
        case .speedRun:
            return (
                .individual,
                [
                    grade(gradePct),
                    AchievementCondition(
                        signal: .executionTimeMs, comparator: .atMost, value: Double(timeMs ?? 2000)),
                ], nil
            )
        case .classRecord, .none:
            return (.record, [], dimension)
        }
    }
}

/// The old closed achievement taxonomy.  Retained only to decode manifests
/// authored before the composable redesign; never written back.
private enum LegacyAchievementKind: String {
    case classGoal, thresholdBadge, testBadge, firstTryPerfect
    case comeback, persistence, speedRun, classRecord
}

/// One predicate over a submission's graded signals.
public struct AchievementCondition: Codable, Equatable, Sendable {
    public let signal: AchievementSignal
    public let comparator: ConditionComparator
    /// The threshold the signal is compared against.  Units follow `signal`:
    /// percent (0–100) for `grade` / `gradeJumpPercent`, a count for `attempts`,
    /// milliseconds for `executionTimeMs`.  Ignored for `testPass`.
    public let value: Double
    /// The graded artifact a `grade` or `testPass` condition reads — a specific
    /// test (`testPass`) or, for `grade`, a suite item / section (nil =
    /// whole-assignment grade).  nil for the submission-level signals.
    public let target: AchievementTarget?

    public init(
        signal: AchievementSignal,
        comparator: ConditionComparator,
        value: Double,
        target: AchievementTarget? = nil
    ) {
        self.signal = signal
        self.comparator = comparator
        self.value = value
        self.target = target
    }
}

/// The graded signal a condition reads.
public enum AchievementSignal: String, Codable, CaseIterable, Sendable {
    /// Grade percent (0–100) of the condition's target (default: whole assignment).
    case grade
    /// This submission's attempt number.
    case attempts
    /// Total execution time of the run, in milliseconds.
    case executionTimeMs
    /// Grade jump (percentage points) versus the immediately preceding attempt.
    case gradeJumpPercent
    /// Whether the condition's target test passed.
    case testPass
}

/// How a condition compares its signal against `value`.
public enum ConditionComparator: String, Codable, Sendable {
    case atLeast  // >=
    case atMost  // <=
    case equals  // ==
}

/// Whether all conditions (AND) or any condition (OR) must hold.
public enum ConditionMatch: String, Codable, Sendable {
    case all
    case any
}

/// Whether an achievement is earned per-student, computed across the class, or a
/// single-holder competitive record.
public enum AchievementScope: String, Codable, Sendable {
    case individual
    case classWide
    /// Competitive: one holder per assignment, ranked on `recordDimension`.
    /// Subsumes the legacy pathfinder / speed-champion / minimalist records.
    case record
}

/// What graded signal an achievement condition reads.
public struct AchievementTarget: Codable, Equatable, Sendable {
    public let kind: TargetKind
    /// The script filename (`suiteItem` / `testPass`) or section id (`section`)
    /// the target refers to; nil for `assignmentGrade`.
    public let ref: String?

    public init(kind: TargetKind, ref: String? = nil) {
        self.kind = kind
        self.ref = ref
    }
}

public enum TargetKind: String, Codable, Sendable {
    /// The whole-assignment grade percent (earnedPoints / totalPoints).
    case assignmentGrade
    /// One suite item's fractional `score` (the partial-credit metric).
    case suiteItem
    /// The aggregate score of one suite section.
    case section
    /// Pass/fail of one referenced test (for a `testPass` condition).
    case testPass
}

/// What a student gets for earning an achievement.
public struct AchievementReward: Codable, Equatable, Sendable {
    public let type: RewardType
    /// Display text — the badge caption or record title.
    public let label: String
    /// Emoji / icon for `badge` rewards (e.g. "🌟"); nil otherwise.
    public let icon: String?
    /// Graded bonus points for `points` rewards (the "pinned grade").  Awarded
    /// positively only; nil for cosmetic rewards.
    public let points: Int?

    public init(type: RewardType, label: String, icon: String? = nil, points: Int? = nil) {
        self.type = type
        self.label = label
        self.icon = icon
        self.points = points
    }
}

public enum RewardType: String, Codable, Sendable {
    /// A cosmetic badge shown on the student's submission.
    case badge
    /// A one-holder record title (class records).
    case title
    /// A positive grade bonus.
    case points
}

/// The dimension a `record`-scoped achievement ranks students on.
public enum RecordDimension: String, Codable, Sendable {
    /// Earliest correct (100%) submission — the "Trailblazer" record.
    case firstToSolve
    /// Earliest submission of any kind — the "Pathfinder" record (awarded at
    /// submission time, not on reaching 100%).
    case firstToSubmit
    /// Fastest execution time at 100%.
    case fastest
    /// Fewest attempts to reach 100% — the "Minimalist" record.  The raw value
    /// is a legacy name (it never measured solution length); it stays
    /// `shortest` because manifests already persist it.
    case shortest
}
