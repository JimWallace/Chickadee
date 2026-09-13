// Core/ClassActivity.swift
//
// The optional `activity` block on a manifest: what makes an assignment a
// class activity — a leaderboard challenge, a beat-the-instructor bot, and
// (in later slices) round robins, king of the hill and brackets. See
// docs/class-activities.md for the model and the slice plan.
//
// An activity is an ASSIGNMENT, not a new content type. Everything an activity
// needs — grading, achievements, the deadline, freeze, the LEARN push — hangs
// off an assignment already, and `nil` here means today's behaviour at every
// branch.
//
// Internally an activity is two orthogonal axes: an opponent source (what else
// is in the workspace when the script runs, and how many times it runs) and a
// class aggregation (how the class's results combine). The instructor never
// sees the axes. They pick ONE kind, and the kind fixes both.

/// The activity kinds this build can author and grade.
///
/// The catalog is deliberately narrow — each kind lands with the slice that
/// makes it work end to end, because a kind the runner cannot execute is a
/// silent misroute, not a feature. Kinds that need an opponent in the
/// workspace (round robin, king of the hill, brackets) arrive with the opponent
/// primitive.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    /// The instructor bundles a grader-only bot; the student's program plays
    /// it. The match script reports the outcome as `score` (credit) and
    /// `metric` (the leaderboard's sort key).
    case beatTheInstructor
    /// No opponent at all. The script measures the submission — a tour length,
    /// a compression ratio, a wins count against a fixed suite — and reports
    /// it as `metric`. The leaderboard ranks on it, highest first.
    case bestMetric

    /// Two-or-three-word chrome label.
    public var displayName: String {
        switch self {
        case .beatTheInstructor: return "Beat the instructor"
        case .bestMetric: return "Best metric"
        }
    }

    /// One sentence for agents and fine print; what the kind does and where
    /// the number it ranks on comes from.
    public var summary: String {
        switch self {
        case .beatTheInstructor:
            return
                "The student's program plays a grader-only bot the instructor bundles; the match "
                + "script reports credit as `score` and the ranking number as `metric`."
        case .bestMetric:
            return
                "No opponent: the script measures the submission and reports the number as "
                + "`metric`; the leaderboard ranks on it, highest first."
        }
    }

    /// Whether this kind's class aggregation is a leaderboard — every kind in
    /// this slice, but the axis is real: a round robin aggregates to standings
    /// and a bug hunt to a union, and neither ranks on `metric`.
    public var aggregatesToLeaderboard: Bool {
        switch self {
        case .beatTheInstructor, .bestMetric: return true
        }
    }
}

/// Whether students may open the assignment's leaderboard.
///
/// Hidden by default, deliberately: every existing assignment already carries
/// seeded `record` achievements, and a leaderboard that rendered on every
/// assignment would change what students see today. Staff always see it.
public enum LeaderboardVisibility: String, Codable, CaseIterable, Sendable {
    case hidden
    case visible
}

/// The manifest's `activity` block.
///
/// Every field but `kind` decodes with a default, so a block written by a
/// later build with more fields still reads here; a block whose `kind` this
/// build does not know does NOT — an unrecognised enum case throws and takes
/// the whole manifest with it. That is why `TestProperties.runnerSanitized()`
/// strips the block: a runner learns what it needs from the job, never from an
/// enum it may predate.
public struct ClassActivity: Codable, Equatable, Sendable {
    public let kind: ActivityKind
    public let leaderboardVisibility: LeaderboardVisibility

    public init(kind: ActivityKind, leaderboardVisibility: LeaderboardVisibility = .hidden) {
        self.kind = kind
        self.leaderboardVisibility = leaderboardVisibility
    }

    private enum CodingKeys: String, CodingKey {
        case kind, leaderboardVisibility
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ActivityKind.self, forKey: .kind)
        leaderboardVisibility =
            try c.decodeIfPresent(LeaderboardVisibility.self, forKey: .leaderboardVisibility) ?? .hidden
    }

    /// True when students may open the leaderboard.
    public var leaderboardVisibleToStudents: Bool { leaderboardVisibility == .visible }
}
