// APIServer/Routes/Web/WebRoutes+Leaderboard.swift
//
// GET /testsetups/:testSetupID/leaderboard — a class activity's ranking
// (docs/class-activities.md). Reached by students through the vanity path
// `/:courseCode/:assignmentSlug/leaderboard` and from their submission page.
//
// Students are named by their per-course handle and their chickadee, never by
// name: the avatar is the identity primitive the leaderboard was designed on
// (docs/student-avatars.md §3), and this page has no identity code of its own.
// Course staff see a real name beside the handle, because a grading dispute
// needs the mapping and nobody else does.
//
// Hidden by default. A student reaches a hidden leaderboard as a 404 — the
// same answer the vanity routes give for anything a student is not meant to
// enumerate — and staff always reach it, with a chip saying it is hidden.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    @Sendable
    func leaderboardPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db),
            let activity = setup.decodedManifest()?.activity,
            activity.kind.aggregatesToLeaderboard
        else { throw Abort(.notFound) }

        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        if !isStaff {
            try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
            guard activity.leaderboardVisibleToStudents else { throw Abort(.notFound) }
        }

        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        let showsStandings = activity.kind.aggregation == .standings
        let rows =
            showsStandings
            ? []
            : try await buildLeaderboardRows(
                setup: setup, viewerID: user.id, includeNames: isStaff, on: req.db)
        let standings =
            showsStandings
            ? try await buildStandingRows(
                setup: setup, viewerID: user.id, includeNames: isStaff, on: req.db)
            : []
        let champion = try await buildChampionPresentation(
            setup: setup, activity: activity, viewerID: user.id, includeNames: isStaff, on: req.db)
        let showsBracket = activity.kind.aggregation == .bracket
        let tournament =
            showsBracket
            ? try await buildTournamentPresentation(
                setup: setup, viewerID: user.id, includeNames: isStaff, on: req.db)
            : nil
        let showsUnion = activity.kind.aggregation == .union
        let union =
            showsUnion
            ? try await buildUnionPresentation(
                setup: setup, viewerID: user.id, includeNames: isStaff, on: req.db)
            : nil

        let session = LiveSessionPresentation.make(activity)
        let context =
            LeaderboardContext(
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                kindLabel: activity.kind.displayName,
                isStaff: isStaff,
                visibleToStudents: activity.leaderboardVisibleToStudents,
                rows: rows,
                hasHill: activity.kind.opponentSource == .champion,
                champion: champion,
                showsStandings: showsStandings,
                standings: standings,
                showsBracket: showsBracket,
                hasTournament: tournament != nil,
                tournament: tournament,
                showsUnion: showsUnion,
                hasUnion: union != nil,
                union: union,
                hasWindow: session != nil,
                window: session,
                // Two decisions, deliberately not one nil. Whether the page
                // shows a line is a copy question — an open-ended session is
                // just an open assignment and says nothing — while whether it
                // refreshes is about whether anything can still change, which
                // an open-ended session emphatically can.
                pollsLive: activity.window.map { $0.state(at: Date()) != .afterClose } ?? false,
                hasPollUntil: activity.window?.closesAtISO != nil,
                pollUntilISO: activity.window?.closesAtISO ?? "",
                currentUser: req.currentUserContext)

        // Two representations, one query, the shape every polled page here
        // uses: `?fragment=body` renders the SAME partial the page rendered
        // inline, so the refresh cannot drift from what it replaces.
        guard req.query[String.self, at: "fragment"] == "body" else {
            return try await req.view.render("leaderboard", context).encodeResponse(for: req)
        }
        return try await req.view.render("_leaderboard-body", context)
            .encodePollFragment(for: req)
    }
}

/// Both halves of a union activity as the page shows them, by handle and
/// bird. Nil when no match has landed yet, so the page can say so once
/// rather than printing two empty tables.
func buildUnionPresentation(
    setup: APITestSetup, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> UnionPresentation? {
    let tally = try await unionTally(setup: setup, on: db)
    guard tally.targetCount > 0 else { return nil }
    let identities = try await RankedIdentities.load(
        userIDs: tally.kills.map(\.userID) + tally.defences.map(\.userID),
        courseID: setup.courseID, on: db)

    var kills: [UnionKillRow] = []
    for tally in tally.kills {
        guard
            let identity = try await identities.presentation(
                for: tally.userID, includeName: includeNames, fallbackLabel: "Student", on: db)
        else { continue }
        kills.append(
            UnionKillRow(
                handle: identity.handle, name: identity.name,
                defeated: tally.defeated, faced: tally.faced,
                isViewer: tally.userID == viewerID, avatar: identity.avatar))
    }

    var defences: [UnionDefenceRow] = []
    for tally in tally.defences {
        guard
            let identity = try await identities.presentation(
                for: tally.userID, includeName: includeNames, fallbackLabel: "Student", on: db)
        else { continue }
        let statusText: String
        if tally.defeated {
            statusText = "defeated"
        } else if tally.faced == 0 {
            statusText = "not tested yet"
        } else {
            statusText = "holding"
        }
        defences.append(
            UnionDefenceRow(
                handle: identity.handle, name: identity.name,
                faced: tally.faced, statusText: statusText,
                isViewer: tally.userID == viewerID, avatar: identity.avatar))
    }

    // Counted from the rows the page SHOWS, not from the tally: a student
    // who has since dropped keeps no row here (their enrollment carried the
    // handle), and a denominator that counted them would not match the
    // table under it.
    let defeated = defences.filter { $0.statusText == "defeated" }.count
    return UnionPresentation(
        summaryText: "\(defeated) of \(defences.count) submissions defeated so far.",
        kills: kills,
        defences: defences)
}

/// The latest tournament run as the page shows it: its status, the winner
/// once there is one, and every round's matches by handle and bird. Nil
/// when no run has been started. Entrants are named from the run's frozen
/// snapshot, so a student who has since dropped still appears in the
/// bracket they played.
func buildTournamentPresentation(
    setup: APITestSetup, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> TournamentPresentation? {
    guard let (run, slots) = try await latestTournament(testSetupID: setup.id ?? "", on: db) else { return nil }
    let entrants = run.entrants
    let identities = try await RankedIdentities.load(
        userIDs: entrants.map(\.userID), courseID: setup.courseID, on: db)
    var bySeed: [Int: TournamentEntrantPresentation] = [:]
    for entrant in entrants {
        let identity = try await identities.presentation(
            for: entrant.userID, includeName: includeNames, fallbackLabel: "Seed \(entrant.seed)", on: db)
        // A dropped entrant keeps their seed on the bracket they played.
        bySeed[entrant.seed] = TournamentEntrantPresentation(
            seed: entrant.seed,
            handle: identity?.handle ?? "Seed \(entrant.seed)",
            name: identity?.name ?? "",
            isViewer: entrant.userID == viewerID,
            hasAvatar: identity != nil,
            avatar: identity?.avatar)
    }
    func entrant(_ seed: Int?) -> TournamentEntrantPresentation? { seed.flatMap { bySeed[$0] } }

    var rounds: [TournamentRoundPresentation] = []
    for slot in slots {
        let home = entrant(slot.homeSeed)
        let away = entrant(slot.awaySeed)
        let resultText: String
        if slot.awaySeed == nil {
            resultText = "bye"
        } else if slot.winnerSeed != nil {
            // The "won" tag beside the entrant says who; the cell says only
            // that the match is decided.
            resultText = "decided"
        } else {
            resultText = "in progress"
        }
        let match = TournamentMatchPresentation(
            home: home, away: away, hasAway: away != nil,
            resultText: resultText,
            homeWon: slot.winnerSeed == slot.homeSeed,
            awayWon: slot.awaySeed != nil && slot.winnerSeed == slot.awaySeed)
        if let index = rounds.firstIndex(where: { $0.number == slot.round }) {
            rounds[index].matches.append(match)
        } else {
            rounds.append(TournamentRoundPresentation(number: slot.round, matches: [match]))
        }
    }
    let winner = run.winnerUserID.flatMap { winnerID in entrants.first { $0.userID == winnerID } }
        .flatMap { entrant($0.seed) }
    return TournamentPresentation(
        statusText: tournamentStatusText(run: run),
        isComplete: run.status == APITournamentRun.Status.complete,
        hasWinner: winner != nil,
        winner: winner,
        rounds: rounds)
}

/// The hill's holder for the page, or nil when the activity has no hill or
/// no student holds it yet (the bot, or nobody, does). Same handle-and-bird
/// identity as a ranking row; staff also see the name.
func buildChampionPresentation(
    setup: APITestSetup, activity: ClassActivity, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> ChampionPresentation? {
    guard activity.kind.opponentSource == .champion,
        let champion = try await currentChampion(testSetupID: setup.id ?? "", on: db),
        let user = try await APIUser.find(champion.userID, on: db),
        let enrollment = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == setup.courseID)
            .filter(\.$userID == champion.userID)
            .first()
    else { return nil }
    let handle = try await AvatarStore.ensureHandle(for: enrollment, on: db) ?? ""
    let spec = try await AvatarStore.ensureSpec(for: user, on: db)
    let accessibility: AvatarAccessibility = handle.isEmpty ? .labelled("Champion") : .decorative
    // The model requires the date; the fallback only keeps the two strings
    // non-optional so the template has no empty shape to render.
    let crownedAt = champion.crownedAt ?? Date()
    return ChampionPresentation(
        handle: handle,
        name: includeNames ? staffFacingName(user) : "",
        crownedAtISO: ISO8601DateFormatter().string(from: crownedAt),
        crownedAtText: waterlooDateTimeFormatter().string(from: crownedAt),
        defencesText: champion.defences == 1 ? "1 defence" : "\(champion.defences) defences",
        isViewer: champion.userID == viewerID,
        avatar: AvatarPresentation(for: spec, size: .small, accessibility: accessibility))
}

// MARK: - Context

struct LeaderboardContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    /// The activity kind's chrome label, e.g. "Best metric".
    let kindLabel: String
    /// Staff see real names and the hidden-from-students chip.
    let isStaff: Bool
    let visibleToStudents: Bool
    let rows: [LeaderboardRow]
    /// True for a king-of-the-hill activity: the page shows who holds the
    /// hill, or that the bot still does.
    let hasHill: Bool
    /// The hill's holder; nil when no student holds it yet.
    let champion: ChampionPresentation?
    /// True for a round robin: the page shows the standings table (played,
    /// won, drawn, lost, average score) instead of the metric ranking.
    let showsStandings: Bool
    let standings: [StandingRow]
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
    /// True when the activity runs to a live-session window, so the page
    /// carries the state line and refreshes itself while it is open.
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

/// A union activity's two tables plus the one-line count above them.
struct UnionPresentation: Encodable {
    /// "7 of 24 submissions defeated so far."
    let summaryText: String
    let kills: [UnionKillRow]
    let defences: [UnionDefenceRow]
}

/// One student's tests, by what they defeated.
struct UnionKillRow: Encodable {
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    let defeated: Int
    let faced: Int
    let isViewer: Bool
    let avatar: AvatarPresentation
}

/// One student's code, by how it has held up.
struct UnionDefenceRow: Encodable {
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    let faced: Int
    /// "holding", "defeated" or "not tested yet". Plain text in the table:
    /// early on nearly every row is holding, so badging the ordinary state
    /// would paint the column one colour and cue nothing.
    let statusText: String
    let isViewer: Bool
    let avatar: AvatarPresentation
}

/// The latest tournament run as the page shows it.
struct TournamentPresentation: Encodable {
    /// One sentence naming the schedule and where the run stands.
    let statusText: String
    let isComplete: Bool
    let hasWinner: Bool
    let winner: TournamentEntrantPresentation?
    let rounds: [TournamentRoundPresentation]
}

struct TournamentRoundPresentation: Encodable {
    let number: Int
    var matches: [TournamentMatchPresentation]
}

/// One match of a round. `hasAway` is false for a bye.
struct TournamentMatchPresentation: Encodable {
    let home: TournamentEntrantPresentation?
    let away: TournamentEntrantPresentation?
    let hasAway: Bool
    let resultText: String
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
struct StandingRow: Encodable {
    /// Competition ranking on the standings order; equal keys share a rank.
    let rank: Int
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    let played: Int
    let wins: Int
    let draws: Int
    let losses: Int
    /// The average match score, as the page prints a metric.
    let averageText: String
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

struct LeaderboardRow: Encodable {
    /// Competition ranking: equal metrics share a rank and the next rank skips.
    let rank: Int
    /// The per-course pseudonym. Empty only when the course has exhausted the
    /// handle space, in which case the bird alone identifies the row.
    let handle: String
    /// The real name, staff only; empty for a student viewer.
    let name: String
    let metricText: String
    /// True on the viewer's own row.
    let isViewer: Bool
    let avatar: AvatarPresentation
}

// MARK: - Rows

/// The ranking rows for `setup`, best first. Handles and avatars are
/// materialised on first view (`AvatarStore`), so a student who has never
/// opened their account page still appears under a stable pseudonym.
///
/// Batched: one query for the users, one for the course's enrollments; the
/// per-row calls only write when a handle or spec is missing, which happens
/// once per student for the life of the course.
func buildLeaderboardRows(
    setup: APITestSetup, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> [LeaderboardRow] {
    let entries = try await leaderboardEntries(testSetupID: setup.id ?? "", on: db)
    guard !entries.isEmpty else { return [] }
    let identities = try await RankedIdentities.load(
        userIDs: entries.map(\.userID), courseID: setup.courseID, on: db)

    var rows: [LeaderboardRow] = []
    var rank = 0
    var previousMetric: Double?
    for (index, entry) in entries.enumerated() {
        guard identities.isOnRoster(entry.userID) else { continue }
        if entry.metric != previousMetric {
            rank = index + 1
            previousMetric = entry.metric
        }
        guard
            let identity = try await identities.presentation(
                for: entry.userID, includeName: includeNames, fallbackLabel: "Student \(rank)", on: db)
        else { continue }
        rows.append(
            LeaderboardRow(
                rank: rank,
                handle: identity.handle,
                name: identity.name,
                metricText: formatLeaderboardMetric(entry.metric),
                isViewer: entry.userID == viewerID,
                avatar: identity.avatar))
    }
    return rows
}

/// The standings rows for a round robin, best first (`activityStandings`),
/// under the same handle-and-bird identity as a ranking row.
func buildStandingRows(
    setup: APITestSetup, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> [StandingRow] {
    let standings = try await activityStandings(testSetupID: setup.id ?? "", on: db)
    guard !standings.isEmpty else { return [] }
    let identities = try await RankedIdentities.load(
        userIDs: standings.map(\.userID), courseID: setup.courseID, on: db)

    var rows: [StandingRow] = []
    var rank = 0
    var previousKey: StandingKey?
    for (index, standing) in standings.enumerated() {
        guard identities.isOnRoster(standing.userID) else { continue }
        let key = StandingKey(standing)
        if key != previousKey {
            rank = index + 1
            previousKey = key
        }
        guard
            let identity = try await identities.presentation(
                for: standing.userID, includeName: includeNames, fallbackLabel: "Student \(rank)", on: db)
        else { continue }
        rows.append(
            StandingRow(
                rank: rank,
                handle: identity.handle,
                name: identity.name,
                played: standing.played,
                wins: standing.wins,
                draws: standing.draws,
                losses: standing.losses,
                averageText: formatLeaderboardMetric(standing.averageScore),
                isViewer: standing.userID == viewerID,
                avatar: identity.avatar))
    }
    return rows
}

/// The part of a standings row that decides its rank: two rows with equal
/// keys share a rank.
private struct StandingKey: Equatable {
    let averageScore: Double
    let wins: Int
    let played: Int

    init(_ standing: APIActivityStanding) {
        averageScore = standing.averageScore
        wins = standing.wins
        played = standing.played
    }
}

/// The users and enrollments behind a set of ranked rows, loaded in two
/// queries, and the handle-and-bird presentation of each.
struct RankedIdentities {
    let userByID: [UUID: APIUser]
    let enrollmentByUser: [UUID: APICourseEnrollment]

    struct Presentation {
        let handle: String
        let name: String
        let avatar: AvatarPresentation
    }

    static func load(userIDs: [UUID], courseID: UUID, on db: Database) async throws -> RankedIdentities {
        let ids = Array(Set(userIDs))
        let users = try await APIUser.query(on: db).filter(\.$id ~~ ids).all()
        var userByID: [UUID: APIUser] = [:]
        for user in users { if let id = user.id { userByID[id] = user } }
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID ~~ ids)
            .all()
        var enrollmentByUser: [UUID: APICourseEnrollment] = [:]
        for enrollment in enrollments { enrollmentByUser[enrollment.userID] = enrollment }
        return RankedIdentities(userByID: userByID, enrollmentByUser: enrollmentByUser)
    }

    /// False for a student who has since dropped: the roster is what a
    /// classmate is ranked against, and their enrollment carried the handle.
    func isOnRoster(_ userID: UUID) -> Bool {
        userByID[userID] != nil && enrollmentByUser[userID] != nil
    }

    /// nil when `isOnRoster` is false.
    func presentation(
        for userID: UUID, includeName: Bool, fallbackLabel: String, on db: Database
    ) async throws -> Presentation? {
        guard let user = userByID[userID], let enrollment = enrollmentByUser[userID] else { return nil }
        let handle = try await AvatarStore.ensureHandle(for: enrollment, on: db) ?? ""
        let spec = try await AvatarStore.ensureSpec(for: user, on: db)
        // Decorative when the handle carries the identity; the bird must
        // announce whose it is only when there is no handle beside it.
        let accessibility: AvatarAccessibility = handle.isEmpty ? .labelled(fallbackLabel) : .decorative
        return Presentation(
            handle: handle,
            name: includeName ? staffFacingName(user) : "",
            avatar: AvatarPresentation(for: spec, size: .small, accessibility: accessibility))
    }
}

/// The name staff see beside a handle: the display name when the roster has
/// one, else the username.
private func staffFacingName(_ user: APIUser) -> String {
    let display = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return display.isEmpty ? user.username : display
}

/// A metric as the page prints it: an integer stays an integer ("1234"), a
/// fraction keeps up to three decimals with no trailing zeros ("0.75").
func formatLeaderboardMetric(_ metric: Double) -> String {
    if metric == metric.rounded(), abs(metric) < 1e15 {
        return String(format: "%.0f", metric)
    }
    var text = String(format: "%.3f", metric)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}
