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

/// What else is in the workspace when a match script runs — the first of the
/// two hidden axes. The kind fixes it; the instructor never chooses it.
///
/// Only the sources this build can stage. `champion` (king of the hill) and
/// `classmates` (round robins, brackets) arrive with the slices that make the
/// worker able to stage them, because a source the worker cannot stage is a
/// silent misroute, not a feature.
public enum ActivityOpponentSource: String, Codable, CaseIterable, Sendable {
    /// No opponent. The script measures the submission on its own.
    case none
    /// A grader-only support file the instructor bundles — the bot. The
    /// worker stages it into the opponent directory the script reads through
    /// `CHICKADEE_OPPONENT_DIR`.
    case supportFile
    /// The current champion's submission (king of the hill). The server
    /// hands the worker the champion's submission to stage; until a student
    /// holds the hill the bundled bot (`opponentFile`) holds it, and with no
    /// bot the first passing match takes an empty hill.
    case champion
    /// Every other student's latest submission (round robin). One job plays
    /// them all — the worker stages each in turn and runs the suite once per
    /// opponent — and reports one aggregated outcome per suite entry plus a
    /// per-match row for each. With no classmate yet, the bundled bot stands
    /// in so the first submitter still has a match.
    case classmates
    /// The one classmate a tournament schedule pairs the entrant with
    /// (brackets). Each pairing is its own job with ONE staged submission —
    /// the hill's runner contract, not the matrix's, which is why it shares
    /// the hill's capability token. A student's own submission on such an
    /// assignment plays the bundled bot, if one is chosen, as practice.
    case paired

    /// True when a match needs an opponent staged beside the submission.
    /// Everything that hangs off an opponent — the worker's `activity-match`
    /// capability, the browser-grading refusal, the opponent directory — asks
    /// this, never the kind.
    public var stagesAnOpponent: Bool {
        switch self {
        case .none: return false
        case .supportFile, .champion, .classmates, .paired: return true
        }
    }

    /// The build capability a runner must advertise to be handed a job with
    /// this opponent, or nil when there is nothing to stage. Per source, not
    /// one token for all: a build that stages a support file may predate
    /// staging a submission, and the gate has to tell them apart.
    public var requiredRunnerCapability: RunnerCapability? {
        switch self {
        case .none: return nil
        case .supportFile: return .activityMatch
        case .champion, .paired: return .activityOpponentSubmission
        case .classmates: return .activityMatrix
        }
    }
}

/// How the class's results combine — the second hidden axis. The instructor
/// never chooses it; the kind fixes it, and the leaderboard page renders the
/// table it names.
public enum ActivityAggregation: String, Codable, CaseIterable, Sendable {
    /// A ranking on the highest `metric` any of a student's submissions
    /// reported, best-so-far (`leaderboard_entries`).
    case leaderboard
    /// A ranking on match results — wins, draws, losses and average score
    /// over a student's latest submission (`activity_standings`). Not
    /// best-so-far: a resubmission replaces the row.
    case standings
    /// A tournament run on frozen entrants (`tournament_runs`): the page
    /// shows the bracket's rounds and the winner, not a ranking.
    case bracket
}

/// The activity kinds this build can author and grade.
///
/// The catalog is deliberately narrow — each kind lands with the slice that
/// makes it work end to end, because a kind the runner cannot execute is a
/// silent misroute, not a feature. Kinds that need a classmate or a champion in
/// the workspace (round robin, king of the hill, brackets) arrive with the
/// opponent source that stages them.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    /// The instructor bundles a grader-only bot; the student's program plays
    /// it. The match script reports the outcome as `score` (credit) and
    /// `metric` (the leaderboard's sort key).
    case beatTheInstructor
    /// No opponent at all. The script measures the submission — a tour length,
    /// a compression ratio, a wins count against a fixed suite — and reports
    /// it as `metric`. The leaderboard ranks on it, highest first.
    case bestMetric
    /// King of the hill: the submission plays the current champion, and a
    /// match the script passes (exit 0) takes the hill. The bundled bot holds
    /// the hill until a student does.
    case kingOfTheHill
    /// Round robin: the submission plays every classmate's latest submission
    /// and the class is ranked in standings — wins, draws, losses and average
    /// match score. Feeds achievements, never the grade of record.
    case roundRobin
    /// Tournament: an instructor starts a single-elimination bracket or a
    /// Swiss tournament on a snapshot of every student's latest submission;
    /// each pairing is a match job, rounds advance as matches land, and the
    /// winner holds the `tournamentWinner` record. Feeds achievements only.
    case elimination

    /// Two-or-three-word chrome label.
    public var displayName: String {
        switch self {
        case .beatTheInstructor: return "Beat the instructor"
        case .bestMetric: return "Best metric"
        case .kingOfTheHill: return "Beat the champion"
        case .roundRobin: return "Round robin"
        case .elimination: return "Tournament"
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
        case .kingOfTheHill:
            return
                "King of the hill: the submission plays the current champion's submission (the "
                + "bundled bot until a student holds the hill); a match the script passes takes the "
                + "hill, and the leaderboard ranks on `metric` beside the champion."
        case .roundRobin:
            return
                "Round robin: one job plays the submission against every classmate's latest "
                + "submission (the bundled bot until a classmate exists) and the class is ranked in "
                + "standings by wins, draws, losses and average match score; standings feed "
                + "achievements, never the grade of record."
        case .elimination:
            return
                "Tournament: an instructor runs a single-elimination bracket or a Swiss tournament "
                + "on a snapshot of every student's latest submission (run_tournament); each pairing "
                + "is a match job whose script passes (exits 0) when the first entrant beats the one "
                + "staged as the opponent, rounds advance as matches land, and the winner holds the "
                + "tournament record; a student's own submission plays the bundled bot, if any, as "
                + "practice."
        }
    }

    /// Whether this kind has a ranking page at all — every kind so far; a bug
    /// hunt's union aggregation would not. Which table that page shows is
    /// `aggregation`.
    public var aggregatesToLeaderboard: Bool {
        switch self {
        case .beatTheInstructor, .bestMetric, .kingOfTheHill, .roundRobin, .elimination: return true
        }
    }

    /// The aggregation axis. Exhaustive for the same reason `opponentSource`
    /// is: a kind added without an answer does not compile.
    public var aggregation: ActivityAggregation {
        switch self {
        case .beatTheInstructor, .bestMetric, .kingOfTheHill: return .leaderboard
        case .roundRobin: return .standings
        case .elimination: return .bracket
        }
    }

    /// The opponent axis. Exhaustive on purpose: a kind added without an
    /// answer here does not compile, so it cannot ship as a leaderboard
    /// challenge whose bot is never staged.
    public var opponentSource: ActivityOpponentSource {
        switch self {
        case .beatTheInstructor: return .supportFile
        case .bestMetric: return .none
        case .kingOfTheHill: return .champion
        case .roundRobin: return .classmates
        case .elimination: return .paired
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
    /// For a kind whose opponent source is `supportFile`: the bare filename of
    /// the support file the worker stages as the opponent (the bot). For
    /// `champion`: the bot that holds the hill until a student does. Nil until
    /// the instructor chooses one — the kind may be set before the bot is
    /// uploaded — and always nil for a kind with no opponent.
    public let opponentFile: String?

    public init(
        kind: ActivityKind,
        leaderboardVisibility: LeaderboardVisibility = .hidden,
        opponentFile: String? = nil
    ) {
        self.kind = kind
        self.leaderboardVisibility = leaderboardVisibility
        self.opponentFile = opponentFile
    }

    private enum CodingKeys: String, CodingKey {
        case kind, leaderboardVisibility, opponentFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ActivityKind.self, forKey: .kind)
        leaderboardVisibility =
            try c.decodeIfPresent(LeaderboardVisibility.self, forKey: .leaderboardVisibility) ?? .hidden
        opponentFile = try c.decodeIfPresent(String.self, forKey: .opponentFile)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(leaderboardVisibility, forKey: .leaderboardVisibility)
        // Omitted when nil, so a slice-1 block's bytes are unchanged.
        try c.encodeIfPresent(opponentFile, forKey: .opponentFile)
    }

    /// True when students may open the leaderboard.
    public var leaderboardVisibleToStudents: Bool { leaderboardVisibility == .visible }

    /// True when grading this activity stages an opponent beside the
    /// submission — the question every opponent-dependent seam asks (the
    /// claim gate, the browser-grading refusal, the job's opponent).
    ///
    /// For `supportFile` this needs a chosen file too. Until the instructor
    /// chooses the bot, nothing is staged and the assignment grades exactly as
    /// a slice-1 activity did — on any runner, with a hand-wired bot if the
    /// script has one — so shipping the primitive changed no existing
    /// assignment's path. A script written for the primitive still fails
    /// loudly on its own when the directory is unset (the fixture does), and
    /// the edit page's picker says so. `champion` stages whoever holds the
    /// hill, file or not, so the kind itself is worker-only.
    public var stagesAnOpponent: Bool {
        switch kind.opponentSource {
        case .none: return false
        case .supportFile: return opponentFile != nil
        case .champion, .classmates, .paired: return true
        }
    }

    /// True when the kind takes an opponent file at all — what decides
    /// whether the picker renders, chosen or not.
    public var takesAnOpponentFile: Bool { kind.opponentSource.stagesAnOpponent }

    /// The same block with a different opponent file, everything else kept.
    public func withOpponentFile(_ file: String?) -> ClassActivity {
        ClassActivity(kind: kind, leaderboardVisibility: leaderboardVisibility, opponentFile: file)
    }

    /// The same block with a different leaderboard visibility, everything
    /// else kept — so a visibility toggle cannot drop the opponent file.
    public func withLeaderboardVisibility(_ visibility: LeaderboardVisibility) -> ClassActivity {
        ClassActivity(kind: kind, leaderboardVisibility: visibility, opponentFile: opponentFile)
    }
}
