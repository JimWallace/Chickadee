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

import Foundation

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
    /// A union of what the class produced, read two ways from the same
    /// matches: which classmates' work the class has collectively defeated,
    /// and how each classmate's own work held up. Materialises nothing of
    /// its own — both halves are queries over `match_results`.
    case union
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
    /// Tests versus implementations: every student submits both, and one job
    /// runs their tests against every classmate's latest submission. Each
    /// match is read TWICE — as a kill for the student whose test found the
    /// fault, and as a fault against the classmate whose work was tested —
    /// so the class sees which work it has collectively defeated and whose
    /// work held up. Feeds achievements only.
    case testsVersusImplementations

    /// Two-or-three-word chrome label.
    public var displayName: String {
        switch self {
        case .beatTheInstructor: return "Beat the instructor"
        case .bestMetric: return "Best metric"
        case .kingOfTheHill: return "Beat the champion"
        case .roundRobin: return "Round robin"
        case .elimination: return "Tournament"
        case .testsVersusImplementations: return "Tests and code"
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
        case .testsVersusImplementations:
            return
                "Tests and code: every student submits both, and each student's tests run against "
                + "every classmate's latest submission, counting once for the test that finds a "
                + "fault and once against the code that has it."
        }
    }

    /// Whether this kind has a ranking page at all — every kind so far; a bug
    /// hunt's union aggregation would not. Which table that page shows is
    /// `aggregation`.
    public var aggregatesToLeaderboard: Bool {
        switch self {
        case .beatTheInstructor, .bestMetric, .kingOfTheHill, .roundRobin, .elimination,
            .testsVersusImplementations:
            return true
        }
    }

    /// The aggregation axis. Exhaustive for the same reason `opponentSource`
    /// is: a kind added without an answer does not compile.
    public var aggregation: ActivityAggregation {
        switch self {
        case .beatTheInstructor, .bestMetric, .kingOfTheHill: return .leaderboard
        case .roundRobin: return .standings
        case .elimination: return .bracket
        case .testsVersusImplementations: return .union
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
        case .roundRobin, .testsVersusImplementations: return .classmates
        case .elimination: return .paired
        }
    }
}

/// Where a live session stands relative to its window.
///
/// Named for the session rather than for the activity because `ActivityWindow`
/// is already taken, by the admin dashboard's chart range (day / week / term).
/// Two unrelated senses of "activity window" in one build is how a call site
/// ends up reading the wrong one and compiling.
public enum LiveSessionState: String, Codable, CaseIterable, Sendable {
    /// The window is set and has not opened yet.
    case beforeOpen
    /// Submissions are being accepted.
    case open
    /// The window has closed.
    case afterClose
}

/// The live-session window: when an activity accepts submissions.
///
/// SEPARATE FROM THE DEADLINE, and not a replacement for it. An assignment's
/// `dueAt` is a date students plan around, moved by extensions and slip days
/// and softened by a claim window; this is the fifty minutes of a lecture. One
/// is coursework policy and carries grade consequences, the other is a gate on
/// a room, so folding them together would mean a slip day silently extending a
/// live contest, or a contest's end time closing an assignment.
///
/// Both bounds are optional and independently useful: an open end is a
/// challenge that starts when the instructor says so and runs until the
/// assignment closes; an open start is one that runs until a fixed moment.
/// Neither set is no window at all, which is what every activity has today.
///
/// THE BOUNDS ARE STORED AS ISO-8601 STRINGS, not as `Date`. `ManifestCodec`
/// documents that `TestProperties` carries no `Date` field and that its plain
/// encoder/decoder pair is sufficient because of it — a `Date` here would
/// encode as a bare seconds-since-2001 Double, unreadable in a hand-authored
/// manifest and correct only as long as every decoder on the path shares one
/// date strategy. The manifest is decoded by several. A string is decoded the
/// same way by all of them.
///
/// An unparseable bound reads as no bound: the window fails OPEN. A typo an
/// instructor cannot see must not lock a class out of their own session, and
/// the supported doors refuse one at save time so a stored bound is one
/// somebody wrote on purpose.
public struct LiveSessionWindow: Codable, Equatable, Sendable {
    /// When submissions start being accepted, ISO-8601; nil accepts from the
    /// moment the assignment opens.
    public let opensAtISO: String?
    /// When they stop, ISO-8601; nil accepts until the assignment closes.
    public let closesAtISO: String?

    public init(opensAtISO: String? = nil, closesAtISO: String? = nil) {
        self.opensAtISO = opensAtISO?.isEmpty == true ? nil : opensAtISO
        self.closesAtISO = closesAtISO?.isEmpty == true ? nil : closesAtISO
    }

    public init(opensAt: Date?, closesAt: Date?) {
        self.init(
            opensAtISO: opensAt.map(Self.format), closesAtISO: closesAt.map(Self.format))
    }

    /// A formatter per call, as every other ISO-8601 site in this codebase
    /// does: `ISO8601DateFormatter` is not `Sendable`, so a shared static one
    /// does not compile under strict concurrency, and the allocation is
    /// nothing beside the file write a submission already does.
    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    /// Parses an ISO-8601 instant, or nil when it is not one.
    ///
    /// Fractional seconds are accepted as well as omitted, because the two
    /// producers write different shapes: a browser `datetime-local` field
    /// resolves to whole seconds, and an agent passing a timestamp through a
    /// JSON encoder may not.
    public static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return formatter(fractionalSeconds: false).date(from: iso)
            ?? formatter(fractionalSeconds: true).date(from: iso)
    }

    /// Renders an instant the way this type stores one.
    public static func format(_ date: Date) -> String {
        formatter(fractionalSeconds: false).string(from: date)
    }

    public var opensAt: Date? { Self.parse(opensAtISO) }
    public var closesAt: Date? { Self.parse(closesAtISO) }

    /// True when this window bounds anything. An unbounded window is stored as
    /// nil rather than as an empty block, so a manifest cannot carry a window
    /// that says nothing.
    ///
    /// Asked of the STORED strings rather than the parsed dates: a bound that
    /// is present but unparseable is still an authored bound, and treating it
    /// as absent would silently drop it on the next rebuild.
    public var isBounded: Bool { opensAtISO != nil || closesAtISO != nil }

    /// True when both bounds parse. A stored bound that does not is the
    /// fail-open case above; the save-time refusal is what keeps it rare.
    public var boundsAreReadable: Bool {
        (opensAtISO == nil || opensAt != nil) && (closesAtISO == nil || closesAt != nil)
    }

    /// True when the bounds are in order. A window that closes before it opens
    /// accepts nothing ever, which no author means, so it is refused at save
    /// rather than stored and puzzled over.
    public var boundsAreOrdered: Bool {
        guard let opensAt, let closesAt else { return true }
        return closesAt > opensAt
    }

    /// Where `now` falls. The bounds are half-open — a submission landing
    /// exactly at `closesAt` is out — because a countdown that reaches zero has
    /// to mean the same thing to the student watching it and to the server
    /// reading the clock.
    public func state(at now: Date) -> LiveSessionState {
        if let opensAt, now < opensAt { return .beforeOpen }
        if let closesAt, now >= closesAt { return .afterClose }
        return .open
    }

    /// True when a submission arriving at `now` is inside the window.
    public func accepts(at now: Date) -> Bool { state(at: now) == .open }

    /// The next moment the state changes, which is what a countdown counts
    /// down to; nil once nothing is left to wait for.
    public func nextBoundary(at now: Date) -> Date? {
        switch state(at: now) {
        case .beforeOpen: return opensAt
        case .open: return closesAt
        case .afterClose: return nil
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
    /// The live-session window, when the activity runs to a clock. Nil — the
    /// default and what every activity before this carried — means the
    /// assignment's own open/closed state is the only gate.
    public let window: LiveSessionWindow?

    public init(
        kind: ActivityKind,
        leaderboardVisibility: LeaderboardVisibility = .hidden,
        opponentFile: String? = nil,
        window: LiveSessionWindow? = nil
    ) {
        self.kind = kind
        self.leaderboardVisibility = leaderboardVisibility
        self.opponentFile = opponentFile
        // An unbounded window is no window: storing an empty block would put
        // a field on the manifest that says nothing and make "has a window"
        // two different questions at two different call sites.
        self.window = (window?.isBounded == true) ? window : nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, leaderboardVisibility, opponentFile, window
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ActivityKind.self, forKey: .kind)
        leaderboardVisibility =
            try c.decodeIfPresent(LeaderboardVisibility.self, forKey: .leaderboardVisibility) ?? .hidden
        opponentFile = try c.decodeIfPresent(String.self, forKey: .opponentFile)
        let decoded = try c.decodeIfPresent(LiveSessionWindow.self, forKey: .window)
        window = (decoded?.isBounded == true) ? decoded : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(leaderboardVisibility, forKey: .leaderboardVisibility)
        // Omitted when nil, so a slice-1 block's bytes are unchanged.
        try c.encodeIfPresent(opponentFile, forKey: .opponentFile)
        try c.encodeIfPresent(window, forKey: .window)
    }

    /// True when a submission arriving at `now` is inside the live-session
    /// window. An activity with no window accepts whenever the assignment
    /// does, which is what every activity before slice 8 did.
    public func acceptsSubmissions(at now: Date) -> Bool {
        window?.accepts(at: now) ?? true
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
        ClassActivity(
            kind: kind, leaderboardVisibility: leaderboardVisibility, opponentFile: file,
            window: window)
    }

    /// The same block with a different leaderboard visibility, everything
    /// else kept — so a visibility toggle cannot drop the opponent file.
    public func withLeaderboardVisibility(_ visibility: LeaderboardVisibility) -> ClassActivity {
        ClassActivity(
            kind: kind, leaderboardVisibility: visibility, opponentFile: opponentFile,
            window: window)
    }

    /// The same block with a different live-session window, everything else
    /// kept — the third of these for the third reason: each of the Activity
    /// section's forms saves one field, and a rebuild that dropped a
    /// neighbour's would lose a bot or close a leaderboard on a window edit.
    public func withWindow(_ window: LiveSessionWindow?) -> ClassActivity {
        ClassActivity(
            kind: kind, leaderboardVisibility: leaderboardVisibility, opponentFile: opponentFile,
            window: window)
    }
}
