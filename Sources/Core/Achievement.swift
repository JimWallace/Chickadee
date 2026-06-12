// Core/Achievement.swift

/// An instructor-authored reward attached to one assignment — the generalized,
/// per-assignment form of Chickadee's previously-hardcoded badge and
/// class-achievement system.
///
/// Achievements are **server-evaluated and display-only**: they never run as a
/// per-submission test, and `TestProperties.runnerSanitized()` strips them from
/// the runner-facing manifest so a runner never has to decode an
/// `AchievementKind` case it doesn't know (the same rationale as
/// `patternFamilies` / `notebookChecks`).
///
/// One `Achievement` expresses both the legacy hardcoded rewards (First-Try
/// Perfect; the pathfinder / speed-champion / minimalist class records) and the
/// new collaborative class goal, distinguished by `kind`.  Per-kind parameters
/// live in the optional fields (`threshold`, `classFraction`,
/// `recordDimension`) — the same idiom `PatternFamily` and `NotebookCheck` use.
public struct Achievement: Codable, Equatable, Sendable {
    public let id: String
    /// Student-facing label, e.g. "Class Goal: 80% reach mastery".
    public let name: String
    /// Optional longer description shown to students ("how to earn this").
    public let detail: String?
    public let kind: AchievementKind
    public let scope: AchievementScope
    public let reward: AchievementReward
    /// Which graded signal the condition reads (a specific test, a section, or
    /// the whole-assignment grade).
    public let target: AchievementTarget
    /// Per-student metric cutoff in `0...1` (fraction of the `target` earned).
    /// Used by `classGoal` and `thresholdBadge`.
    public let threshold: Double?
    /// Proportion of the class (`0...1`) that must reach `threshold` for a
    /// `classGoal` to be fully met.
    public let classFraction: Double?
    /// Which dimension a `classRecord` ranks students on.
    public let recordDimension: RecordDimension?
    /// Attempt-count cutoff: the *max* attempt for `firstTryPerfect` (def 1)
    /// and the *min* attempt for `persistence` (def 5).  The ≤/≥ sense is
    /// intrinsic to the kind.
    public let attemptThreshold: Int?
    /// Total-execution cutoff in ms for `speedRun` (def 2000).
    public let timeThresholdMs: Int?
    /// Minimum grade jump (percentage points) between submissions for
    /// `comeback` (def 50).
    public let jumpThresholdPercent: Int?
    /// Suite section this achievement renders under; nil = the trailing
    /// "Achievements" block.
    public let sectionID: String?

    public init(
        id: String,
        name: String,
        detail: String? = nil,
        kind: AchievementKind,
        scope: AchievementScope,
        reward: AchievementReward,
        target: AchievementTarget = AchievementTarget(kind: .assignmentGrade),
        threshold: Double? = nil,
        classFraction: Double? = nil,
        recordDimension: RecordDimension? = nil,
        attemptThreshold: Int? = nil,
        timeThresholdMs: Int? = nil,
        jumpThresholdPercent: Int? = nil,
        sectionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.kind = kind
        self.scope = scope
        self.reward = reward
        self.target = target
        self.threshold = threshold
        self.classFraction = classFraction
        self.recordDimension = recordDimension
        self.attemptThreshold = attemptThreshold
        self.timeThresholdMs = timeThresholdMs
        self.jumpThresholdPercent = jumpThresholdPercent
        self.sectionID = sectionID
    }
}

/// The variety of achievement — the discriminator that says which optional
/// parameters apply and how it is evaluated.
public enum AchievementKind: String, CaseIterable, Codable, Sendable {
    /// Collaborative: at least `classFraction` of the class reaches `threshold`
    /// on `target`.  Awards a positive, fractional `points` bonus to everyone
    /// who submitted, scaled by class progress.  Evaluated by the periodic
    /// class sweep; locks at the deadline.
    case classGoal
    /// Individual: this student's best `target` value is ≥ `threshold`.
    case thresholdBadge
    /// Individual: a referenced (often secret) test passes — content-specific
    /// logic lives in the instructor's test; this just maps the pass to a badge.
    case testBadge
    /// Individual: 100% on the first attempt.  Subsumes the legacy First-Try
    /// Perfect ("Ace") badge.
    case firstTryPerfect
    /// Individual: jumped a large margin (≥50 percentage points) between
    /// submissions.  Subsumes the legacy "Rally" comeback badge.
    case comeback
    /// Individual: reached 100% only after several attempts (≥5).  Subsumes the
    /// legacy "Tenacious" persistence badge.
    case persistence
    /// Individual: scored 100% with a fast total execution (<2 s).  Subsumes
    /// the legacy "Swift" speed badge.
    case speedRun
    /// Competitive, one holder per assignment, ranked on `recordDimension`.
    /// Subsumes the legacy pathfinder / speed-champion / minimalist records.
    /// Kept for back-compat; new assignments lean on the collaborative kinds.
    case classRecord
}

/// Whether an achievement is earned per-student or computed across the class.
public enum AchievementScope: String, Codable, Sendable {
    case individual
    case classWide
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
    /// Pass/fail of one referenced test (for `testBadge`).
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

/// The dimension a `classRecord` ranks students on.
public enum RecordDimension: String, Codable, Sendable {
    /// Earliest correct (100%) submission — the "Trailblazer" record.
    case firstToSolve
    /// Earliest submission of any kind — the "Pathfinder" record (awarded at
    /// submission time, not on reaching 100%).
    case firstToSubmit
    /// Fastest execution time.
    case fastest
    /// Shortest solution.
    case shortest
}
