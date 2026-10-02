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
            let activity = setup.decodedManifest()?.activity
        else { throw Abort(.notFound) }

        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        if !isStaff {
            try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
            guard activity.leaderboardVisibleToStudents else { throw Abort(.notFound) }
        }

        if req.query[String.self, at: "present"] == "1" {
            // Present mode is for the room, and only staff start it.
            guard isStaff else { throw Abort(.notFound) }
            return try await leaderboardPresentPage(
                req: req, user: user, setup: setup, activity: activity)
        }

        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        // Each flag names its own aggregation. The metric board used to be
        // "none of the other three", which a fifth aggregation would have
        // satisfied silently (#1745).
        let showsStandings = activity.kind.aggregation == .standings
        let showsBracket = activity.kind.aggregation == .bracket
        let showsUnion = activity.kind.aggregation == .union
        let showsMetricBoard = activity.kind.aggregation == .leaderboard
        let boardURL = "/testsetups/\(setupID)/leaderboard"
        // Staff always read the whole list; a student reads a window of it
        // unless they ask for the rest.
        let showingAll = isStaff || req.query[String.self, at: "all"] == "1"
        let reader = LeaderboardReader.page(user: user, isStaff: isStaff)
        let board =
            showsMetricBoard
            ? try await buildLeaderboard(
                setup: setup, reader: reader, showAll: showingAll, on: req.db)
            : LeaderboardBoard.empty
        let standingsBoard =
            showsStandings
            ? try await buildStandingsBoard(
                setup: setup, reader: reader, showAll: showingAll, on: req.db)
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
                setup: setup, reader: reader, showAll: showingAll,
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

/// Who reads a board, and what the read may do. Staff read names and the
/// whole list. A classmate reading the page locks every handle it shows
/// (docs/student-avatars.md §3); a staff view, the page or Present mode,
/// locks nothing (#1757).
struct LeaderboardReader {
    let user: APIUser
    let isStaff: Bool
    /// The viewer whose read locks the handles shown; nil when nothing locks.
    let lockingFor: UUID?

    /// A classmate or a staff member reading the leaderboard page.
    static func page(user: APIUser, isStaff: Bool) -> LeaderboardReader {
        LeaderboardReader(user: user, isStaff: isStaff, lockingFor: isStaff ? nil : user.id)
    }

    /// Present mode: nameless like a student view, locking nothing like a
    /// staff one.
    static func presenting(as user: APIUser) -> LeaderboardReader {
        LeaderboardReader(user: user, isStaff: false, lockingFor: nil)
    }
}

/// Both halves of a union activity as the page shows them, by handle and
/// bird. Nil when no match has landed yet, so the page can say so once
/// rather than printing two empty tables.
func buildUnionPresentation(
    setup: APITestSetup, reader: LeaderboardReader, showAll: Bool, allURL: String, on db: Database
) async throws -> UnionPresentation? {
    let viewer = reader.user
    let isStaff = reader.isStaff
    let lockingFor = reader.lockingFor
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
                for: kill.userID, includeName: isStaff, lockingFor: lockingFor, fallbackLabel: "Student",
                size: .roster,
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
                for: tally.userID, includeName: isStaff, lockingFor: lockingFor,
                fallbackLabel: "Student", size: .roster,
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
        titleText: "\(found) \(found == 1 ? "fault" : "faults") found",
        noteText:
            "Your code is \(status) · tested \(tested) \(tested == 1 ? "classmate" : "classmates"), tested by \(testedBy)",
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
            isLive: slot.awaySeed != nil && slot.winnerSeed == nil
                && run.status != APITournamentRun.Status.superseded,
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
        showsNames: includeNames,
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
        avatar: AvatarPresentation(
            for: spec, size: .hero, accessibility: accessibility, isStaff: enrollment.role >= .ta))
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
    setup: APITestSetup, reader: LeaderboardReader, showAll: Bool, on db: Database
) async throws -> LeaderboardBoard {
    let viewer = reader.user
    let isStaff = reader.isStaff
    let lockingFor = reader.lockingFor
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
                lockingFor: lockingFor, fallbackLabel: "Student \(rank)",
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
                accessibility: handle.isEmpty ? .labelled("You") : .decorative,
                isStaff: enrollment.role >= .ta),
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
    setup: APITestSetup, reader: LeaderboardReader, showAll: Bool, on db: Database
) async throws -> StandingsBoard {
    let viewer = reader.user
    let isStaff = reader.isStaff
    let lockingFor = reader.lockingFor
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
                for: standing.userID, includeName: isStaff, lockingFor: lockingFor,
                fallbackLabel: "Student \(rank)",
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
            avatar: AvatarPresentation(
                for: spec, size: size, accessibility: accessibility, isStaff: enrollment.role >= .ta))
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
