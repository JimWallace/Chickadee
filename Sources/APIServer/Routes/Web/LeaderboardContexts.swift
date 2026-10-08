// APIServer/Routes/Web/LeaderboardContexts.swift
//
// The view contexts behind the leaderboard pages: the page context, the
// three boards (metric, standings, tournament), the live-session and union
// presentations, and the rows inside them. Built by
// `WebRoutes+Leaderboard.swift` and `WebRoutes+LeaderboardPresent.swift`;
// read by `leaderboard.leaf`, its partials and the Present page (#1716).

import Core
import Fluent
import Foundation
import Vapor

struct LeaderboardContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    /// The course above the title, as its course tab names it: the code and
    /// the short term, e.g. "CS135 F26". Empty for a setup whose course is gone.
    let courseLabel: String
    /// The assignment's 6-character ID, for the staff visibility form.
    let assignmentPublicID: String
    /// The activity kind's chrome label, e.g. "Best metric".
    let kindLabel: String
    /// Staff see real names and the hidden-from-students chip.
    let isStaff: Bool
    let visibleToStudents: Bool
    /// True for the ranked-by-metric kinds, whose page is the you card and the
    /// ranked list; the other kinds keep their own bodies.
    let showsMetricBoard: Bool
    let rows: [LeaderboardRow]
    /// What the list shows: every row for staff and for "show all", else the
    /// top places and the viewer's neighbourhood with gap rows between.
    let displayItems: [LeaderboardWindowItem<LeaderboardRow>]
    /// The viewer's own standing, for a student; nil for staff.
    let you: ViewerStanding?
    let hasYou: Bool
    /// Students ranked, and enrolled students still without a metric.
    let rankedCount: Int
    let unrankedCount: Int
    /// "31 ranked · 4 enrolled students haven't reported a metric yet."
    let staffSummary: String
    /// A student looking at the whole list, who is offered the way back.
    let showingAll: Bool
    let allURL: String
    let boardURL: String
    /// The filter box appears only over a full list of eight or more rows.
    let showFilter: Bool
    /// Staff can search names; a student's page holds none.
    let filterPlaceholder: String
    /// The background refresh's URL; it keeps `?all=1` so a full list stays
    /// full.
    let pollURL: String
    /// The ranked quantity's name. The activity manifest carries none, so this
    /// is the generic word.
    let metricLabel: String
    /// True for a king-of-the-hill activity: the page shows who holds the
    /// hill, or that the bot still does.
    let hasHill: Bool
    /// The hill's holder; nil when no student holds it yet.
    let champion: ChampionPresentation?
    /// True for a round robin: the page shows the standings table (played,
    /// won, drawn, lost, average score) instead of the metric ranking.
    let showsStandings: Bool
    let standings: [StandingRow]
    let standingList: LeaderboardListContext<StandingRow>
    /// True for a tournament kind: the page shows the latest run's bracket.
    let showsBracket: Bool
    /// True when a run has been started; the template gates on this, never
    /// on the optional itself.
    let hasTournament: Bool
    let tournament: TournamentPresentation?
    /// True for a tests-and-code kind: the page shows what the class has
    /// defeated and whose code is holding.
    let showsUnion: Bool
    /// True once the roster has code to test; the template gates on this.
    let hasUnion: Bool
    let union: UnionPresentation?
    /// True when the page shows the session's state line. A COPY question
    /// only — whether the page refreshes is `pollsLive`, which answers a
    /// different one, and an open-ended session says yes to that and no to
    /// this.
    let hasWindow: Bool
    let window: LiveSessionPresentation?
    /// True while a session is still ahead of or inside its window: the
    /// results region carries the background-refresh attributes, so a
    /// projected leaderboard stays current without anybody touching it.
    ///
    /// BEFORE the session counts too, and that is not a nicety. The countdown
    /// is a client-side tick over a SERVER-rendered label, so a page opened at
    /// 13:58 for a 14:00 start would otherwise sit there reading "Opens 2
    /// minutes ago" — the label frozen at load while the time ticks past it.
    /// Refreshing is what re-renders the label.
    ///
    /// False on every assignment with no window, which is what keeps this
    /// page's cost unchanged for them, and false once the session has ended.
    let pollsLive: Bool
    /// True when there is an instant to stop refreshing at.
    let hasPollUntil: Bool
    /// That instant — the window's close, ISO-8601. A page loaded at 13:58
    /// must not keep polling all evening because the session ended at 14:50
    /// and nobody closed the tab. An open-ended session has none, and then
    /// polls while the tab is open, as the three dashboards already do.
    let pollUntilISO: String
    let currentUser: CurrentUserContext?
}

/// The live-session line above the results, and what the page needs to keep
/// itself current (docs/class-activities.md, slice 8).
struct LiveSessionPresentation: Encodable {
    /// "Opens", "Closes" or "Closed" — the label before the time.
    let label: String
    /// The boundary being counted down to, formatted; the no-JS fallback.
    let boundaryText: String
    /// The same instant as ISO-8601 for `.js-relative-time`, which is the
    /// countdown: the component already ticks a `data-iso` node on every page
    /// and picks its cadence from the freshest stamp, so a session clock is
    /// one attribute rather than a second timer.
    let boundaryISO: String
    /// True once the window has closed: nothing is left to count down to, so
    /// the line reads as a statement and the page stops refreshing.
    let isClosed: Bool
    /// True while submissions are being accepted.
    let isOpen: Bool

    /// nil when the activity has no window at all, which is every activity
    /// before slice 8 and every one that does not run to a clock.
    static func make(_ activity: ClassActivity, now: Date = Date()) -> LiveSessionPresentation? {
        guard let window = activity.window else { return nil }
        let formatter = waterlooDateTimeFormatter()
        let state = window.state(at: now)
        guard let boundary = window.nextBoundary(at: now) else {
            // Closed, or open with no end: both have nothing to count down
            // to, and they say opposite things, so only the closed one gets a
            // line. An open-ended session is just an open assignment.
            guard state == .afterClose else { return nil }
            let closedAt = window.closesAt.map(formatter.string(from:)) ?? ""
            return LiveSessionPresentation(
                label: "Closed", boundaryText: closedAt,
                boundaryISO: window.closesAtISO ?? "", isClosed: true, isOpen: false)
        }
        return LiveSessionPresentation(
            label: state == .beforeOpen ? "Opens" : "Closes",
            boundaryText: formatter.string(from: boundary),
            boundaryISO: LiveSessionWindow.format(boundary),
            isClosed: false,
            isOpen: state == .open)
    }
}

/// A union activity's two lists plus the one-line count above them.
struct UnionPresentation: Encodable, Sendable {
    /// "7 of 24 submissions defeated so far."
    let summaryText: String
    let kills: [UnionKillRow]
    /// The Tests list as the viewer is shown it: the window, or everything.
    let killList: LeaderboardListContext<UnionKillRow>
    let defences: [UnionDefenceRow]
    /// A student's card; nil for staff.
    let hasYou: Bool
    let you: UnionYouCard?
}

/// The viewer's card above a union activity's lists.
struct UnionYouCard: Encodable, Sendable {
    let isRanked: Bool
    let handle: String
    let hasHandle: Bool
    let avatar: AvatarPresentation
    /// "You · Quiet Cedar".
    let kicker: String
    /// "Your tests found 3 faults · your code is holding".
    let titleText: String
    /// "Tested 11 classmates · 4 have tested you".
    let noteText: String
    let privacyLine: String
    let submitURL: String
}

/// One student's tests, by what they defeated.
struct UnionKillRow: Encodable, Sendable {
    let rank: Int
    let rankText: String
    let isTied: Bool
    let rankTier: String
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    let defeated: Int
    let faced: Int
    /// The defeated count as printed in the value column.
    let valueText: String
    /// "tested 11".
    let detailsText: String
    let isViewer: Bool
    let avatar: AvatarPresentation
}

/// One student's code, by how it has held up.
struct UnionDefenceRow: Encodable, Sendable {
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    let faced: Int
    /// "holding", "defeated" or "not tested yet". Plain text, never a pill:
    /// early on nearly every row is holding, so badging the ordinary state
    /// would paint the column one colour and cue nothing.
    let statusText: String
    /// "holding · tested by 4" — the status as details text.
    let detailsText: String
    let isViewer: Bool
    let avatar: AvatarPresentation
}

/// The latest tournament run as the page shows it.
struct TournamentPresentation: Encodable {
    /// Whether the bracket prints names beside handles; staff pages only.
    let showsNames: Bool
    /// One sentence naming the schedule and where the run stands.
    let statusText: String
    let isComplete: Bool
    let hasWinner: Bool
    let winner: TournamentEntrantPresentation?
    let rounds: [TournamentRoundPresentation]
}

struct TournamentRoundPresentation: Encodable {
    let number: Int
    /// "Round 1", … and "Final" for the last round of a single elimination.
    let label: String
    var matches: [TournamentMatchPresentation]
}

/// One match of a round. `hasAway` is false for a bye.
struct TournamentMatchPresentation: Encodable {
    let home: TournamentEntrantPresentation?
    let away: TournamentEntrantPresentation?
    let hasAway: Bool
    let resultText: String
    /// True for a match that has two entrants and no result yet.
    let isLive: Bool
    let homeWon: Bool
    let awayWon: Bool
}

/// An entrant by handle and bird; a dropped student keeps their seed and an
/// empty handle, since their enrollment carried it.
struct TournamentEntrantPresentation: Encodable {
    let seed: Int
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    let isViewer: Bool
    let hasAvatar: Bool
    let avatar: AvatarPresentation?
}

/// One row of a round robin's standings.
struct StandingRow: Encodable, Sendable {
    /// Competition ranking on the standings order; equal keys share a rank.
    let rank: Int
    let rankText: String
    let isTied: Bool
    let rankTier: String
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    /// "P 5 · W 3 · D 1 · L 1" — plain text under the handle, because four
    /// columns of counts are more than a row at this width can carry.
    let detailsText: String
    /// The average match score, as the page prints a metric.
    let valueText: String
    let isViewer: Bool
    let avatar: AvatarPresentation
}

/// The hill's holder as the leaderboard shows them.
struct ChampionPresentation: Encodable {
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    /// When the hill was taken: the ISO instant the relative-time script
    /// renders from, and the absolute text it shows without JS.
    let crownedAtISO: String
    let crownedAtText: String
    /// "3 defences".
    let defencesText: String
    let isViewer: Bool
    let avatar: AvatarPresentation
}

struct LeaderboardRow: Encodable, Sendable {
    /// Competition ranking: equal metrics share a rank and the next rank skips.
    let rank: Int
    /// The rank as printed: "14", or "14=" for a tie.
    let rankText: String
    let isTied: Bool
    /// "1", "2" or "3" for the three places with a disc colour, else empty.
    let rankTier: String
    /// The per-course pseudonym. Empty only when the course has exhausted the
    /// handle space, in which case the bird alone identifies the row.
    let handle: String
    /// The real name, staff only; empty for a student viewer.
    let name: String
    /// The login name, staff only.
    let username: String
    let metricText: String
    /// True on the viewer's own row.
    let isViewer: Bool
    let avatar: AvatarPresentation
    /// "Tied · reached it first", on the viewer's row and their tie partners'
    /// only. Empty elsewhere: a stranger's tie is not the viewer's business.
    let tieNote: String
    let hasTieNote: Bool
    /// Staff only: "6 submissions", and the submission that set the best.
    let submissionCountText: String
    let bestAtISO: String
    /// The same instant as text, shown until the relative-time script runs.
    let bestAtText: String
    let bestSubmissionURL: String
}

/// One line of a windowed list: a row, or a run of rows folded away.
struct LeaderboardWindowItem<Row: Encodable & Sendable>: Encodable, Sendable {
    let isGap: Bool
    let gapLabel: String
    let row: Row?
}

/// What the shared list partial (`_leaderboard-list.leaf`) needs: the lines,
/// the heading over the value column, and the two facts the partial cannot
/// read once it is given a sub-context as its root. Every row type it renders
/// carries `rankText`, `rankTier`, `handle`, `name`, `detailsText`,
/// `valueText`, `isViewer` and `avatar`.
struct LeaderboardListContext<Row: Encodable & Sendable>: Encodable, Sendable {
    let items: [LeaderboardWindowItem<Row>]
    /// "Average" or "Faults": what the value column counts.
    let valueLabel: String
    let isStaff: Bool
    let allURL: String
    let tableID: String
}

/// The viewer's card at the top of the page.
struct ViewerStanding: Encodable, Sendable {
    /// False when the viewer has no submission on the board yet.
    let isRanked: Bool
    let handle: String
    let hasHandle: Bool
    let avatar: AvatarPresentation
    /// "14th", or "Tied 14th".
    let rankHeadline: String
    /// "of 31".
    let ofText: String
    /// "Your best", or "Your average" on a round robin.
    let bestLabel: String
    let bestText: String
    /// When the best was reached: the ISO instant `.js-relative-time` reads,
    /// and the absolute text shown without JS.
    let hasBestAt: Bool
    let bestAtISO: String
    let bestAtText: String
    /// "+0.004 to pass Golden Sedge"; empty at the top.
    let nextPlaceText: String
    let hasNextPlace: Bool
    /// "Only you and course staff can link Quiet Cedar to you. …"
    let privacyLine: String
    let submitURL: String
}
