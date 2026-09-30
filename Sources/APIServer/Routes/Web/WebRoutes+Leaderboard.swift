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
        let showsBracket = activity.kind.aggregation == .bracket
        let showsUnion = activity.kind.aggregation == .union
        let showsMetricBoard = !showsStandings && !showsBracket && !showsUnion
        let boardURL = "/testsetups/\(setupID)/leaderboard"
        // Staff always read the whole list; a student reads a window of it
        // unless they ask for the rest.
        let showingAll = isStaff || req.query[String.self, at: "all"] == "1"
        let board =
            showsMetricBoard
            ? try await buildLeaderboard(
                setup: setup, viewer: user, isStaff: isStaff, showAll: showingAll, on: req.db)
            : LeaderboardBoard.empty
        let standingsBoard =
            showsStandings
            ? try await buildStandingsBoard(
                setup: setup, viewer: user, isStaff: isStaff, showAll: showingAll, on: req.db)
            : StandingsBoard.empty
        let champion = try await buildChampionPresentation(
            setup: setup, activity: activity, viewerID: user.id, includeNames: isStaff, on: req.db)
        let tournament =
            showsBracket
            ? try await buildTournamentPresentation(
                setup: setup, viewerID: user.id, includeNames: isStaff, on: req.db)
            : nil
        let union =
            showsUnion
            ? try await buildUnionPresentation(
                setup: setup, viewer: user, isStaff: isStaff, showAll: showingAll,
                allURL: "\(boardURL)?all=1", on: req.db)
            : nil

        let listedCount = showsStandings ? standingsBoard.rankedCount : board.rankedCount
        let session = LiveSessionPresentation.make(activity)
        let context =
            LeaderboardContext(
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                assignmentPublicID: assignment?.publicID ?? "",
                kindLabel: activity.kind.displayName,
                isStaff: isStaff,
                visibleToStudents: activity.leaderboardVisibleToStudents,
                showsMetricBoard: showsMetricBoard,
                rows: board.rows,
                displayItems: board.items,
                you: board.you ?? standingsBoard.you,
                hasYou: (board.you ?? standingsBoard.you) != nil,
                rankedCount: showsStandings ? standingsBoard.rankedCount : board.rankedCount,
                unrankedCount: board.unrankedCount,
                staffSummary: board.staffSummary,
                showingAll: showingAll && !isStaff,
                allURL: "\(boardURL)?all=1",
                boardURL: boardURL,
                showFilter: showingAll && listedCount >= LeaderboardBoard.filterThreshold,
                filterPlaceholder: isStaff ? "Filter by handle or name…" : "Filter by handle…",
                pollURL: showingAll && !isStaff
                    ? "\(boardURL)?fragment=body&all=1" : "\(boardURL)?fragment=body",
                metricLabel: "metric",
                hasHill: activity.kind.opponentSource == .champion,
                champion: champion,
                showsStandings: showsStandings,
                standings: standingsBoard.rows,
                standingList: LeaderboardListContext(
                    items: standingsBoard.items, valueLabel: "Average", isStaff: isStaff,
                    allURL: "\(boardURL)?all=1", tableID: "leaderboard-table"),
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
    setup: APITestSetup, viewer: APIUser, isStaff: Bool, showAll: Bool, allURL: String,
    on db: Database
) async throws -> UnionPresentation? {
    let tally = try await unionTally(setup: setup, on: db)
    guard tally.targetCount > 0 else { return nil }
    let identities = try await RankedIdentities.load(
        userIDs: tally.kills.map(\.userID) + tally.defences.map(\.userID),
        courseID: setup.courseID, on: db)

    // Competition ranking over the same key the tally sorts on.
    var killRanks: [Int] = []
    let rosterKills = tally.kills.filter { identities.isOnRoster($0.userID) }
    for (index, kill) in rosterKills.enumerated() {
        let previous = index > 0 ? rosterKills[index - 1] : nil
        let ties = previous.map { $0.defeated == kill.defeated && $0.faced == kill.faced } ?? false
        killRanks.append(ties ? killRanks[index - 1] : index + 1)
    }
    let killTieSizes = Dictionary(killRanks.map { ($0, 1) }, uniquingKeysWith: +)

    var kills: [UnionKillRow] = []
    for (index, kill) in rosterKills.enumerated() {
        let rank = killRanks[index]
        let isTied = (killTieSizes[rank] ?? 1) > 1
        guard
            let identity = try await identities.presentation(
                for: kill.userID, includeName: isStaff, lockingFor: isStaff ? nil : viewer.id, fallbackLabel: "Student", size: .roster,
                on: db)
        else { continue }
        kills.append(
            UnionKillRow(
                rank: rank,
                rankText: LeaderboardStandingText.rankText(rank: rank, isTied: isTied),
                isTied: isTied,
                rankTier: LeaderboardStandingText.tier(rank: rank),
                handle: identity.handle, name: identity.name,
                defeated: kill.defeated, faced: kill.faced,
                valueText: "\(kill.defeated)",
                detailsText: "tested \(kill.faced)",
                isViewer: kill.userID == viewer.id, avatar: identity.avatar))
    }

    var defences: [UnionDefenceRow] = []
    for tally in tally.defences {
        guard
            let identity = try await identities.presentation(
                for: tally.userID, includeName: isStaff, lockingFor: isStaff ? nil : viewer.id, fallbackLabel: "Student", size: .roster,
                on: db)
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
                detailsText: "\(statusText) · tested by \(tally.faced)",
                isViewer: tally.userID == viewer.id, avatar: identity.avatar))
    }

    // Counted from the rows the page SHOWS, not from the tally: a student
    // who has since dropped keeps no row here (their enrollment carried the
    // handle), and a denominator that counted them would not match the
    // table under it.
    let defeated = defences.filter { $0.statusText == "defeated" }.count
    let viewerIndex = kills.firstIndex(where: \.isViewer)
    let you =
        isStaff
        ? nil
        : try await buildUnionYouCard(
            viewer: viewer, setup: setup,
            kill: kills.first(where: \.isViewer), defence: defences.first(where: \.isViewer), on: db)
    return UnionPresentation(
        summaryText: "\(defeated) of \(defences.count) submissions defeated so far.",
        kills: kills,
        killList: LeaderboardListContext(
            items: leaderboardWindowItems(
                rows: kills, ranks: kills.map(\.rank), viewerIndex: viewerIndex,
                showAll: showAll || isStaff),
            valueLabel: "Faults", isStaff: isStaff, allURL: allURL, tableID: "leaderboard-table"),
        defences: defences,
        hasYou: you != nil,
        you: you)
}

/// The viewer's card for a tests-and-code activity: both halves in one place.
private func buildUnionYouCard(
    viewer: APIUser, setup: APITestSetup, kill: UnionKillRow?, defence: UnionDefenceRow?,
    on db: Database
) async throws -> UnionYouCard? {
    guard let identity = try await ViewerIdentity.load(viewer: viewer, setup: setup, on: db) else {
        return nil
    }
    guard kill != nil || defence != nil else {
        return UnionYouCard(
            isRanked: false, handle: identity.handle, hasHandle: !identity.handle.isEmpty,
            avatar: identity.avatar, kicker: "You · \(identity.handle)",
            titleText: "Not on the board yet", noteText: "", privacyLine: identity.privacyLine,
            submitURL: identity.submitURL)
    }
    let found = kill?.defeated ?? 0
    let status = defence?.statusText ?? "not tested yet"
    let tested = kill?.faced ?? 0
    let testedBy = defence?.faced ?? 0
    return UnionYouCard(
        isRanked: true, handle: identity.handle, hasHandle: !identity.handle.isEmpty,
        avatar: identity.avatar, kicker: "You · \(identity.handle)",
        titleText: "Your tests found \(found) \(found == 1 ? "fault" : "faults") · your code is \(status)",
        noteText:
            "Tested \(tested) \(tested == 1 ? "classmate" : "classmates") · \(testedBy) \(testedBy == 1 ? "has" : "have") tested you",
        privacyLine: identity.privacyLine, submitURL: identity.submitURL)
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
            for: entrant.userID, includeName: includeNames,
            lockingFor: includeNames ? nil : viewerID, fallbackLabel: "Seed \(entrant.seed)", on: db)
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
            isLive: slot.awaySeed != nil && slot.winnerSeed == nil,
            homeWon: slot.winnerSeed == slot.homeSeed,
            awayWon: slot.awaySeed != nil && slot.winnerSeed == slot.awaySeed)
        if let index = rounds.firstIndex(where: { $0.number == slot.round }) {
            rounds[index].matches.append(match)
        } else {
            let isFinal = run.tournamentSchedule == .bracket && run.roundCount > 1 && slot.round == run.roundCount
            rounds.append(
                TournamentRoundPresentation(
                    number: slot.round, label: isFinal ? "Final" : "Round \(slot.round)",
                    matches: [match]))
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
    // The same lock as a ranking row: a classmate has now seen this handle.
    if !includeNames, champion.userID != viewerID {
        await AvatarStore.lockHandle(for: enrollment, on: db)
    }
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
        avatar: AvatarPresentation(for: spec, size: .hero, accessibility: accessibility))
}

// MARK: - Context

struct LeaderboardContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
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

/// Everything the metric board needs, built once per request.
struct LeaderboardBoard: Sendable {
    let rows: [LeaderboardRow]
    let items: [LeaderboardWindowItem<LeaderboardRow>]
    let you: ViewerStanding?
    let rankedCount: Int
    let unrankedCount: Int
    let staffSummary: String

    static let filterThreshold = 8
    static let empty = LeaderboardBoard(
        rows: [], items: [], you: nil, rankedCount: 0, unrankedCount: 0, staffSummary: "")
}

// MARK: - Rows

/// The metric board for `setup`: the ranked rows, the list a viewer is shown,
/// and the viewer's own card. Handles and avatars are materialised on first
/// view (`AvatarStore`), so a student who has never opened their account page
/// still appears under a stable pseudonym.
///
/// Batched: one query for the users, one for the course's enrollments; the
/// per-row calls only write when a handle or spec is missing, which happens
/// once per student for the life of the course.
///
/// `isStaff` decides whether names, usernames and submission counts are built
/// at all — a student's page never holds them.
func buildLeaderboard(
    setup: APITestSetup, viewer: APIUser, isStaff: Bool, showAll: Bool, on db: Database
) async throws -> LeaderboardBoard {
    let setupID = setup.id ?? ""
    let allEntries = try await leaderboardEntries(testSetupID: setupID, on: db)
    let identities = try await RankedIdentities.load(
        userIDs: allEntries.map(\.userID), courseID: setup.courseID, on: db)
    // Ranked against the roster: a student who has dropped takes no place.
    let entries = allEntries.filter { identities.isOnRoster($0.userID) }
    let counts = isStaff ? try await leaderboardSubmissionCounts(setupID: setupID, on: db) : [:]
    let unranked = isStaff ? try await unrankedStudentCount(setup: setup, ranked: entries, on: db) : 0

    // Competition ranking over the roster.
    var ranks: [Int] = []
    for (index, entry) in entries.enumerated() {
        ranks.append(index > 0 && entry.metric == entries[index - 1].metric ? ranks[index - 1] : index + 1)
    }
    let tieSizes = Dictionary(ranks.map { ($0, 1) }, uniquingKeysWith: +)
    let viewerIndex = entries.firstIndex { $0.userID == viewer.id }
    let viewerRank = viewerIndex.map { ranks[$0] }
    let firstReached = viewerRank.flatMap { rank in
        entries.indices.filter { ranks[$0] == rank }.compactMap { entries[$0].reachedAt }.min()
    }

    var rows: [LeaderboardRow] = []
    for (index, entry) in entries.enumerated() {
        let rank = ranks[index]
        let isTied = (tieSizes[rank] ?? 1) > 1
        guard
            let identity = try await identities.presentation(
                for: entry.userID, includeName: isStaff,
                lockingFor: isStaff ? nil : viewer.id, fallbackLabel: "Student \(rank)",
                size: .roster, on: db)
        else { continue }
        var tieNote = ""
        if isTied, rank == viewerRank, let first = firstReached, let reached = entry.reachedAt {
            tieNote =
                reached <= first
                ? "Tied · reached it first"
                : "Tied · reached it \(LeaderboardStandingText.duration(seconds: reached.timeIntervalSince(first))) later"
        }
        let submissions = counts[entry.userID] ?? 0
        rows.append(
            LeaderboardRow(
                rank: rank,
                rankText: LeaderboardStandingText.rankText(rank: rank, isTied: isTied),
                isTied: isTied,
                rankTier: LeaderboardStandingText.tier(rank: rank),
                handle: identity.handle,
                name: identity.name,
                username: isStaff ? (identities.userByID[entry.userID]?.username ?? "") : "",
                metricText: formatLeaderboardMetric(entry.metric),
                isViewer: entry.userID == viewer.id,
                avatar: identity.avatar,
                tieNote: tieNote,
                hasTieNote: !tieNote.isEmpty,
                submissionCountText: isStaff
                    ? "\(submissions) \(submissions == 1 ? "submission" : "submissions")" : "",
                bestAtISO: isStaff ? entry.reachedAt.map(ISO8601DateFormatter().string(from:)) ?? "" : "",
                bestAtText: isStaff
                    ? entry.reachedAt.map(waterlooDateTimeFormatter().string(from:)) ?? "" : "",
                bestSubmissionURL: isStaff ? "/submissions/\(entry.submissionID)" : ""))
    }

    let rowViewerIndex = rows.firstIndex(where: \.isViewer)
    let items = leaderboardWindowItems(
        rows: rows, ranks: rows.map(\.rank), viewerIndex: rowViewerIndex, showAll: showAll)
    let you =
        isStaff
        ? nil
        : try await buildViewerStanding(
            viewer: viewer, setup: setup, rows: rows, entries: entries,
            viewerRowIndex: rowViewerIndex, on: db)
    let summary = "\(rows.count) ranked"
    let staffSummary =
        unranked > 0
        ? "\(summary) · \(unranked) enrolled \(unranked == 1 ? "student hasn't" : "students haven't") reported a metric yet."
        : "\(summary)."
    return LeaderboardBoard(
        rows: rows, items: items, you: you, rankedCount: rows.count, unrankedCount: unranked,
        staffSummary: staffSummary)
}

/// The rows as the page lists them: all of them when the viewer may see the
/// whole list, else the window of `LeaderboardWindow`. `ranks` are the rows'
/// competition ranks, best first.
func leaderboardWindowItems<Row: Encodable & Sendable>(
    rows: [Row], ranks: [Int], viewerIndex: Int?, showAll: Bool
) -> [LeaderboardWindowItem<Row>] {
    guard !showAll else {
        return rows.map { LeaderboardWindowItem(isGap: false, gapLabel: "", row: $0) }
    }
    return LeaderboardWindow.slots(ranks: ranks, viewerIndex: viewerIndex).map { slot in
        switch slot {
        case .row(let index):
            return LeaderboardWindowItem(isGap: false, gapLabel: "", row: rows[index])
        case .gap(let count, let low, let high, let trailing):
            return LeaderboardWindowItem(
                isGap: true,
                gapLabel: LeaderboardWindow.gapLabel(
                    count: count, lowRank: low, highRank: high, isTrailing: trailing),
                row: nil)
        }
    }
}

/// How many times each student has submitted to `setupID`, for the staff row.
private func leaderboardSubmissionCounts(setupID: String, on db: Database) async throws -> [UUID: Int] {
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
    var counts: [UUID: Int] = [:]
    for submission in submissions {
        if let userID = submission.userID { counts[userID, default: 0] += 1 }
    }
    return counts
}

/// Enrolled students with no row on the board.
private func unrankedStudentCount(
    setup: APITestSetup, ranked: [APILeaderboardEntry], on db: Database
) async throws -> Int {
    let students = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == setup.courseID)
        .all()
        .filter { $0.role == .student }
    let rankedIDs = Set(ranked.map(\.userID))
    return students.filter { !rankedIDs.contains($0.userID) }.count
}

/// Who the viewer is to the page: their handle and hero bird, from the same
/// store every other row reads, and the lines a card shares across kinds.
struct ViewerIdentity {
    let handle: String
    let avatar: AvatarPresentation
    let privacyLine: String
    let submitURL: String

    /// nil when the viewer is not enrolled in the setup's course.
    static func load(viewer: APIUser, setup: APITestSetup, on db: Database) async throws -> ViewerIdentity? {
        guard let viewerID = viewer.id,
            let enrollment = try await APICourseEnrollment.query(on: db)
                .filter(\.$course.$id == setup.courseID)
                .filter(\.$userID == viewerID)
                .first()
        else { return nil }
        let handle = try await AvatarStore.ensureHandle(for: enrollment, on: db) ?? ""
        let spec = try await AvatarStore.ensureSpec(for: viewer, on: db)
        return ViewerIdentity(
            handle: handle,
            avatar: AvatarPresentation(
                for: spec, size: .hero,
                accessibility: handle.isEmpty ? .labelled("You") : .decorative),
            privacyLine: handle.isEmpty
                ? "" : "Only you and course staff can link \(handle) to you. It stays the same all term.",
            submitURL: "/testsetups/\(setup.id ?? "")/submit")
    }
}

/// The value a card reports for a ranked viewer.
struct ViewerBest {
    /// "Your best", or "Your average".
    let label: String
    let text: String
    /// Nil where the kind has no single moment the value was reached (a round
    /// robin's average).
    let reachedAt: Date?
    let nextPlaceText: String
}

extension ViewerStanding {
    /// The card for a viewer with no row on the board.
    static func notRanked(_ identity: ViewerIdentity) -> ViewerStanding {
        ViewerStanding(
            isRanked: false, handle: identity.handle, hasHandle: !identity.handle.isEmpty,
            avatar: identity.avatar, rankHeadline: "Not on the board yet", ofText: "",
            bestLabel: "", bestText: "", hasBestAt: false, bestAtISO: "", bestAtText: "",
            nextPlaceText: "", hasNextPlace: false, privacyLine: identity.privacyLine,
            submitURL: identity.submitURL)
    }

    /// The card for a ranked viewer.
    static func ranked(
        _ identity: ViewerIdentity, row: (rank: Int, isTied: Bool), total: Int, best: ViewerBest
    ) -> ViewerStanding {
        ViewerStanding(
            isRanked: true, handle: identity.handle, hasHandle: !identity.handle.isEmpty,
            avatar: identity.avatar,
            rankHeadline: LeaderboardStandingText.headline(rank: row.rank, isTied: row.isTied),
            ofText: "of \(total)", bestLabel: best.label, bestText: best.text,
            hasBestAt: best.reachedAt != nil,
            bestAtISO: best.reachedAt.map(ISO8601DateFormatter().string(from:)) ?? "",
            bestAtText: best.reachedAt.map(waterlooDateTimeFormatter().string(from:)) ?? "",
            nextPlaceText: best.nextPlaceText, hasNextPlace: !best.nextPlaceText.isEmpty,
            privacyLine: identity.privacyLine, submitURL: identity.submitURL)
    }
}

/// The viewer's card: their place and best when they are ranked, else the
/// invitation to submit.
private func buildViewerStanding(
    viewer: APIUser, setup: APITestSetup, rows: [LeaderboardRow], entries: [APILeaderboardEntry],
    viewerRowIndex: Int?, on db: Database
) async throws -> ViewerStanding? {
    guard let identity = try await ViewerIdentity.load(viewer: viewer, setup: setup, on: db) else {
        return nil
    }
    // Every entry is on the roster by now, so rows and entries line up.
    guard let index = viewerRowIndex else { return .notRanked(identity) }
    let row = rows[index]
    var nextPlace = ""
    let metrics = entries.map(\.metric)
    if let target = LeaderboardNextPlace.targetIndex(metrics: metrics, viewerIndex: index) {
        let delta = LeaderboardNextPlace.deltaText(metrics[target] - metrics[index])
        let rival = rows[target]
        let name = rival.handle.isEmpty ? LeaderboardStandingText.ordinal(rival.rank) : rival.handle
        nextPlace = "\(delta) to pass \(name)"
    }
    return .ranked(
        identity, row: (row.rank, row.isTied), total: rows.count,
        best: ViewerBest(
            label: "Your best", text: row.metricText, reachedAt: entries[index].reachedAt ?? Date(),
            nextPlaceText: nextPlace))
}

/// A round robin's standings as the page shows them: every row, the list the
/// viewer is shown, and their own card.
struct StandingsBoard: Sendable {
    let rows: [StandingRow]
    let items: [LeaderboardWindowItem<StandingRow>]
    let you: ViewerStanding?
    let rankedCount: Int

    static let empty = StandingsBoard(rows: [], items: [], you: nil, rankedCount: 0)
}

/// The standings for a round robin, best first (`activityStandings`), under
/// the same handle-and-bird identity as a ranking row.
func buildStandingsBoard(
    setup: APITestSetup, viewer: APIUser, isStaff: Bool, showAll: Bool, on db: Database
) async throws -> StandingsBoard {
    let standings = try await activityStandings(testSetupID: setup.id ?? "", on: db)
    let identities = try await RankedIdentities.load(
        userIDs: standings.map(\.userID), courseID: setup.courseID, on: db)
    let ranked = standings.filter { identities.isOnRoster($0.userID) }

    var ranks: [Int] = []
    for (index, standing) in ranked.enumerated() {
        let tiesPrevious = index > 0 && StandingKey(standing) == StandingKey(ranked[index - 1])
        ranks.append(tiesPrevious ? ranks[index - 1] : index + 1)
    }
    let tieSizes = Dictionary(ranks.map { ($0, 1) }, uniquingKeysWith: +)

    var rows: [StandingRow] = []
    for (index, standing) in ranked.enumerated() {
        let rank = ranks[index]
        let isTied = (tieSizes[rank] ?? 1) > 1
        guard
            let identity = try await identities.presentation(
                for: standing.userID, includeName: isStaff, lockingFor: isStaff ? nil : viewer.id, fallbackLabel: "Student \(rank)",
                size: .roster, on: db)
        else { continue }
        rows.append(
            StandingRow(
                rank: rank,
                rankText: LeaderboardStandingText.rankText(rank: rank, isTied: isTied),
                isTied: isTied,
                rankTier: LeaderboardStandingText.tier(rank: rank),
                handle: identity.handle,
                name: identity.name,
                detailsText:
                    "P \(standing.played) · W \(standing.wins) · D \(standing.draws) · L \(standing.losses)",
                valueText: formatLeaderboardMetric(standing.averageScore),
                isViewer: standing.userID == viewer.id,
                avatar: identity.avatar))
    }

    let viewerIndex = rows.firstIndex(where: \.isViewer)
    let items = leaderboardWindowItems(
        rows: rows, ranks: rows.map(\.rank), viewerIndex: viewerIndex, showAll: showAll)
    var you: ViewerStanding?
    if !isStaff, let identity = try await ViewerIdentity.load(viewer: viewer, setup: setup, on: db) {
        if let viewerIndex {
            let row = rows[viewerIndex]
            you = .ranked(
                identity, row: (row.rank, row.isTied), total: rows.count,
                best: ViewerBest(label: "Your average", text: row.valueText, reachedAt: nil, nextPlaceText: ""))
        } else {
            you = .notRanked(identity)
        }
    }
    return StandingsBoard(rows: rows, items: items, you: you, rankedCount: rows.count)
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
    ///
    /// `lockingFor` is the student viewing the page, or nil for a staff view.
    /// Showing a handle to a classmate locks it (docs/student-avatars.md §3):
    /// from then on the student cannot choose a different one.  A student's own
    /// row, and anything staff see, locks nothing.
    func presentation(
        for userID: UUID, includeName: Bool, lockingFor viewerID: UUID?, fallbackLabel: String,
        size: AvatarSize = .small, on db: Database
    ) async throws -> Presentation? {
        guard let user = userByID[userID], let enrollment = enrollmentByUser[userID] else { return nil }
        let handle = try await AvatarStore.ensureHandle(for: enrollment, on: db) ?? ""
        if let viewerID, viewerID != userID {
            await AvatarStore.lockHandle(for: enrollment, on: db)
        }
        let spec = try await AvatarStore.ensureSpec(for: user, on: db)
        // Decorative when the handle carries the identity; the bird must
        // announce whose it is only when there is no handle beside it.
        let accessibility: AvatarAccessibility = handle.isEmpty ? .labelled(fallbackLabel) : .decorative
        return Presentation(
            handle: handle,
            name: includeName ? staffFacingName(user) : "",
            avatar: AvatarPresentation(for: spec, size: size, accessibility: accessibility))
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
