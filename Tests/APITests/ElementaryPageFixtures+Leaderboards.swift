// Tests/APITests/ElementaryPageFixtures+Leaderboards.swift
//
// Fixtures for the leaderboard page, its Present mode and the admin runner
// detail page. Each board kind (metric, standings, tournament, tests-and-code,
// king of the hill) renders for a student and for staff, with and without
// rows, and with a live session window.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var leaderboardPages: [ElementaryPageFixture] {
        [leaderboardPage, leaderboardPresentPage, adminRunnerPage]
    }

    static var leaderboardPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "LeaderboardPage",
            archetype: .plainStudentPage,
            renders: LeaderboardSamples.boards.map { LeaderboardPage(page: page(), board: $0.board).render() }
        )
    }

    static var leaderboardPresentPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "LeaderboardPresentPage",
            archetype: .fullBleedApp,
            renders: LeaderboardSamples.presentBoards.map {
                LeaderboardPresentPage(page: page(), board: $0.board).render()
            }
        )
    }

    static var adminRunnerPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "AdminRunnerPage",
            archetype: .titlebarPage,
            renders: LeaderboardSamples.runners.map { $0.page(page(currentUser: signedInAdmin)).render() }
        )
    }
}

/// The sample values behind the fixtures above.
enum LeaderboardSamples {

    static func avatar(_ seed: UInt64, size: AvatarSize = .roster) -> AvatarPresentation {
        AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: seed), size: size, accessibility: .decorative, isStaff: false)
    }

    static let window = LiveSessionPresentation(
        label: "Closes", boundaryText: "Oct 12, 2026 at 2:50 PM", boundaryISO: "2026-10-12T18:50:00Z",
        isClosed: false, isOpen: true)

    static let closedWindow = LiveSessionPresentation(
        label: "Closed", boundaryText: "Oct 12, 2026 at 2:50 PM", boundaryISO: "2026-10-12T18:50:00Z",
        isClosed: true, isOpen: false)

    // MARK: - Rows

    static func metricRow(_ rank: Int, isViewer: Bool = false, tieNote: String = "") -> LeaderboardRow {
        LeaderboardRow(
            rank: rank, rankText: tieNote.isEmpty ? "\(rank)" : "\(rank)=", isTied: !tieNote.isEmpty,
            rankTier: rank <= 3 ? "\(rank)" : "", handle: "Quiet Cedar \(rank)", name: "Student \(rank)",
            username: "s\(rank)", metricText: "0.9\(rank)", isViewer: isViewer, avatar: avatar(UInt64(rank)),
            tieNote: tieNote, hasTieNote: !tieNote.isEmpty, submissionCountText: "\(rank) submissions",
            bestAtISO: "2026-10-0\(rank % 9 + 1)T10:00:00Z", bestAtText: "Oct \(rank % 9 + 1)",
            bestSubmissionURL: "/submissions/sub\(rank)")
    }

    static func standingRow(_ rank: Int, isViewer: Bool = false) -> StandingRow {
        StandingRow(
            rank: rank, rankText: "\(rank)", isTied: false, rankTier: rank <= 3 ? "\(rank)" : "",
            handle: "Golden Sedge \(rank)", name: "Student \(rank)", detailsText: "P 5 · W 3 · D 1 · L 1",
            valueText: "0.\(rank)", isViewer: isViewer, avatar: avatar(UInt64(rank + 20)))
    }

    static func killRow(_ rank: Int, isViewer: Bool = false) -> UnionKillRow {
        UnionKillRow(
            rank: rank, rankText: "\(rank)", isTied: false, rankTier: rank <= 3 ? "\(rank)" : "",
            handle: "Hazy Cache \(rank)", name: "Student \(rank)", defeated: 5 - rank, faced: 11,
            valueText: "\(5 - rank)", detailsText: "tested 11", isViewer: isViewer, avatar: avatar(UInt64(rank + 40)))
    }

    static func defenceRow(_ index: Int, isViewer: Bool = false) -> UnionDefenceRow {
        UnionDefenceRow(
            handle: "Hazy Cache \(index)", name: "Student \(index)", faced: 4, statusText: "holding",
            detailsText: "holding · tested by 4", isViewer: isViewer, avatar: avatar(UInt64(index + 40)))
    }

    static func windowed<Row>(_ rows: [Row], gapAfter: Int? = nil) -> [LeaderboardWindowItem<Row>] {
        var items: [LeaderboardWindowItem<Row>] = []
        for (index, row) in rows.enumerated() {
            items.append(LeaderboardWindowItem(isGap: false, gapLabel: "", row: row))
            if index == gapAfter {
                items.append(LeaderboardWindowItem(isGap: true, gapLabel: "12 more", row: nil))
            }
        }
        return items
    }

    static func viewer(isRanked: Bool, hasHandle: Bool = true) -> ViewerStanding {
        ViewerStanding(
            isRanked: isRanked, handle: hasHandle ? "Quiet Cedar 2" : "", hasHandle: hasHandle,
            avatar: avatar(2, size: .hero), rankHeadline: isRanked ? "2nd" : "Not ranked yet", ofText: "of 31",
            bestLabel: "Your best", bestText: "0.92", hasBestAt: isRanked, bestAtISO: "2026-10-03T10:00:00Z",
            bestAtText: "Oct 3", nextPlaceText: "+0.004 to pass Quiet Cedar 1", hasNextPlace: isRanked,
            privacyLine: "Only you and course staff can link Quiet Cedar 2 to you.",
            submitURL: "/CS135-F26/lab-1")
    }

    static func entrant(
        _ seed: Int, isViewer: Bool = false, named: Bool, hasAvatar: Bool = true
    )
        -> TournamentEntrantPresentation
    {
        TournamentEntrantPresentation(
            seed: seed, handle: hasAvatar ? "Brisk Wren \(seed)" : "", name: named ? "Student \(seed)" : "",
            isViewer: isViewer, avatar: hasAvatar ? avatar(UInt64(seed + 60)) : nil)
    }

    static func tournament(named: Bool, viewer: Int?, complete: Bool) -> TournamentPresentation {
        func match(_ home: Int, _ away: Int?, homeWon: Bool, live: Bool) -> TournamentMatchPresentation {
            TournamentMatchPresentation(
                home: entrant(home, isViewer: viewer == home, named: named),
                away: away.map { entrant($0, isViewer: viewer == $0, named: named, hasAvatar: $0 != 4) },
                hasAway: away != nil, resultText: "", isLive: live, homeWon: homeWon,
                awayWon: away != nil && !homeWon && !live)
        }
        let first = TournamentRoundPresentation(
            number: 1, label: "Round 1",
            matches: [
                match(1, 4, homeWon: true, live: false), match(2, 3, homeWon: false, live: false),
                match(5, nil, homeWon: true, live: false),
            ])
        let final = TournamentRoundPresentation(
            number: 2, label: "Final", matches: [match(1, 3, homeWon: complete, live: !complete)])
        let winner = complete ? entrant(1, isViewer: viewer == 1, named: named) : nil
        return TournamentPresentation(
            showsNames: named,
            statusText: complete ? "Single elimination · complete." : "Single elimination · round 2 of 2.",
            scheduleName: "Single elimination", progressLabel: "Round", progressValue: complete ? "2 of 2" : "1 of 2",
            isComplete: complete, hasWinner: winner != nil, winner: winner, rounds: [first, final])
    }

    static func champion(isViewer: Bool, named: Bool) -> ChampionPresentation {
        ChampionPresentation(
            handle: "Quiet Cedar 1", name: named ? "Student 1" : "", crownedAtISO: "2026-10-04T10:00:00Z",
            crownedAtText: "Oct 4", defencesText: "3 defences", isViewer: isViewer, avatar: avatar(1, size: .hero))
    }

    static func union(isStaff: Bool, you: Bool, ranked: Bool, kills: Int) -> UnionPresentation {
        let killRows = (1...4).map { killRow($0, isViewer: !isStaff && $0 == 2) }
        let card = UnionYouCard(
            isRanked: ranked, handle: "Hazy Cache 2", hasHandle: ranked, avatar: avatar(42, size: .hero),
            kicker: "You · Hazy Cache 2", titleText: "Your tests found 3 faults · your code is holding",
            noteText: "Tested 11 classmates · 4 have tested you", privacyLine: "Only you and course staff can link it.",
            submitURL: "/CS135-F26/lab-1")
        return UnionPresentation(
            summaryText: "7 of 24 submissions defeated so far.",
            kills: Array(killRows.prefix(kills)),
            killList: LeaderboardListContext(
                items: windowed(Array(killRows.prefix(2)), gapAfter: 0), valueLabel: "Faults", isStaff: isStaff,
                allURL: "/testsetups/ts1/leaderboard?all=1", tableID: "leaderboard-tests-table"),
            defences: [defenceRow(1), defenceRow(2, isViewer: !isStaff)],
            hasYou: you, you: you ? card : nil)
    }

    // MARK: - The leaderboard page

    enum Kind { case metric, standings, bracket, union, hill }

    // One function builds every board, so the list below stays readable.
    static func board(
        _ kind: Kind, isStaff: Bool, empty: Bool = false, showingAll: Bool = false, live: Bool = false,
        you: ViewerStanding? = nil, courseLabel: String = "CS135 F26", visible: Bool = true,
        sessionWindow: LiveSessionPresentation? = nil, winner: Bool = true
    ) -> LeaderboardPresentation {
        let metricRows =
            empty
            ? []
            : (1...4).map {
                metricRow(
                    $0, isViewer: !isStaff && $0 == 2, tieNote: $0 == 2 && !isStaff ? "Tied · reached it first" : "")
            }
        let standingRows = empty ? [] : (1...3).map { standingRow($0, isViewer: !isStaff && $0 == 3) }
        let bracket =
            kind == .bracket && !empty ? tournament(named: isStaff, viewer: isStaff ? nil : 1, complete: winner) : nil
        let unionBoard =
            kind == .union && !empty
            ? Self.union(isStaff: isStaff, you: !isStaff, ranked: you != nil, kills: showingAll ? 2 : 4) : nil
        let standingItems = windowed(standingRows, gapAfter: showingAll ? nil : 0)
        return LeaderboardPresentation(
            testSetupID: "ts1", assignmentTitle: "Lab 1 <fast>", courseLabel: courseLabel, assignmentPublicID: "A1B2C3",
            kindLabel: "Best metric", isStaff: isStaff, visibleToStudents: visible,
            showsMetricBoard: kind == .metric || kind == .hill,
            rows: metricRows, displayItems: windowed(metricRows, gapAfter: showingAll || isStaff ? nil : 1),
            you: you, hasYou: you != nil, rankedCount: kind == .standings ? 9 : 31, unrankedCount: 4,
            staffSummary: "31 ranked · 4 enrolled students haven't reported a metric yet.",
            showingAll: showingAll, allURL: "/testsetups/ts1/leaderboard?all=1",
            boardURL: "/testsetups/ts1/leaderboard",
            showFilter: showingAll || isStaff,
            filterPlaceholder: isStaff ? "Filter by handle or name…" : "Filter by handle…",
            pollURL: "/testsetups/ts1/leaderboard?fragment=body", metricLabel: "metric",
            hasHill: kind == .hill,
            champion: kind == .hill && !empty ? champion(isViewer: !isStaff, named: isStaff) : nil,
            showsStandings: kind == .standings, standings: standingRows,
            standingList: LeaderboardListContext(
                items: standingItems, valueLabel: "Average", isStaff: isStaff,
                allURL: "/testsetups/ts1/leaderboard?all=1", tableID: "leaderboard-table"),
            showsBracket: kind == .bracket, hasTournament: bracket != nil, tournament: bracket,
            showsUnion: kind == .union, hasUnion: unionBoard != nil, union: unionBoard,
            hasWindow: sessionWindow != nil, window: sessionWindow, pollsLive: live,
            hasPollUntil: live && sessionWindow != nil,
            pollUntilISO: live && sessionWindow != nil ? "2026-10-12T18:50:00Z" : "")
    }

    static var boards: [(name: String, board: LeaderboardPresentation)] {
        [
            ("metric student", board(.metric, isStaff: false, you: viewer(isRanked: true))),
            ("metric student unranked", board(.metric, isStaff: false, you: viewer(isRanked: false, hasHandle: false))),
            ("metric student all", board(.metric, isStaff: false, showingAll: true, you: viewer(isRanked: true))),
            ("metric staff", board(.metric, isStaff: true, courseLabel: "", visible: false)),
            ("metric staff live", board(.metric, isStaff: true, live: true, sessionWindow: window)),
            ("metric live no end", board(.metric, isStaff: false, live: true)),
            ("metric closed", board(.metric, isStaff: false, sessionWindow: closedWindow)),
            ("metric empty", board(.metric, isStaff: false, empty: true)),
            ("standings student", board(.standings, isStaff: false, you: viewer(isRanked: true))),
            ("standings all", board(.standings, isStaff: false, showingAll: true)),
            ("standings staff", board(.standings, isStaff: true)),
            ("standings empty", board(.standings, isStaff: true, empty: true)),
            ("bracket student", board(.bracket, isStaff: false)),
            ("bracket staff", board(.bracket, isStaff: true)),
            ("bracket running", board(.bracket, isStaff: true, winner: false)),
            ("bracket empty", board(.bracket, isStaff: false, empty: true)),
            ("union student ranked", board(.union, isStaff: false, you: viewer(isRanked: true))),
            ("union student unranked", board(.union, isStaff: false)),
            ("union student all", board(.union, isStaff: false, showingAll: true)),
            ("union staff", board(.union, isStaff: true)),
            ("union empty", board(.union, isStaff: false, empty: true)),
            ("hill student", board(.hill, isStaff: false, you: viewer(isRanked: true))),
            ("hill staff", board(.hill, isStaff: true)),
            ("hill empty", board(.hill, isStaff: false, empty: true)),
            ("composite staff", composite(.starter, holders: true, live: true)),
            ("composite strip, no holders", composite(sequenceSpec, holders: false, live: false)),
            ("composite missing", composite(nil, holders: false, live: false)),
        ]
    }

    // MARK: - Class composite (docs/class-composite.md)

    static let sequenceSpec = CompositeSpec(
        compositor: .sequence, layout: .count(12),
        contribution: CompositeContributionShape(width: 8, height: 8, frames: 30, format: .rgb8), dealOrder: .rowMajor)

    static func composite(_ spec: CompositeSpec?, holders: Bool, live: Bool) -> LeaderboardPresentation {
        var result = board(.standings, isStaff: true, live: live, sessionWindow: live ? window : nil)
        result.showsComposite = true
        result.compositeBoard = spec.map {
            CompositeBoardPresentation(
                stage: .board(
                    spec: $0, testSetupID: "ts1", present: false, pollUntilISO: live ? "2026-10-12T18:50:00Z" : nil),
                progressText: "2 of 48 tiles complete",
                holders: holders
                    ? [
                        .init(
                            place: "Column 1, row 1", who: "Calm Finch · Ada", stateText: "Passed",
                            tierClass: "tier-open"),
                        .init(
                            place: "Column 2, row 1", who: "Brisk Wren · Alan", stateText: "Did not pass, grading",
                            tierClass: "tier-danger"),
                        .init(
                            place: "Column 3, row 1", who: "Quiet Cedar", stateText: "No contribution", tierClass: ""),
                    ] : [])
        }
        return result
    }

    static func presentComposite(_ spec: CompositeSpec) -> PresentModePresentation {
        var result = present(window: window)
        result.compositeStage = .board(spec: spec, testSetupID: "ts1", present: true, pollUntilISO: nil)
        return result
    }

    // MARK: - Present mode

    static func place(_ rank: Int, champion: Bool = false) -> PresentPlace {
        var place = PresentPlace(
            rank: rank, rankText: "\(rank)", rankTier: rank <= 3 ? "\(rank)" : "", handle: "Quiet Cedar \(rank)",
            valueText: "0.9\(rank)", avatar: avatar(UInt64(rank)))
        place.isChampion = champion
        return place
    }

    static func present(
        places count: Int = 0, bracket: TournamentPresentation? = nil, showsBracket: Bool = false,
        window sessionWindow: LiveSessionPresentation? = nil, champion: Int? = nil, championOnPodium: Bool = false,
        live: Bool = true, arena: Bool = false
    ) -> PresentModePresentation {
        let places = (0..<count).map { place($0 + 1, champion: championOnPodium && champion == $0 + 1) }
        let podium = PresentPlace.podiumOrder(places)
        let winner = bracket?.winner
        return PresentModePresentation(
            testSetupID: "ts1", assignmentTitle: "Lab 1", courseCode: "CS135",
            title: showsBracket ? "Tournament · single elimination" : "Leaderboard · highest metric",
            podium: podium, hasPodium: !places.isEmpty, rest: Array(places.dropFirst(3).prefix(7)),
            rankedCount: places.count, showsBracket: showsBracket, hasTournament: bracket != nil, tournament: bracket,
            entrantCount: bracket == nil ? 0 : 5, hasWinner: winner?.avatar != nil, winnerHandle: winner?.handle ?? "",
            winnerAvatar: winner?.avatar?.resized(to: .hero), hasChampion: champion != nil,
            championHandle: champion.map { "Quiet Cedar \($0)" } ?? "",
            championAvatar: champion.map { avatar(UInt64($0)) },
            championOnPodium: championOnPodium, hasWindow: sessionWindow != nil, window: sessionWindow,
            hasProgress: sessionWindow == nil && bracket != nil, progressLabel: bracket?.progressLabel ?? "",
            progressValue: bracket?.progressValue ?? "", pollsLive: live,
            pollURL: "/testsetups/ts1/leaderboard?present=1&fragment=present", boardURL: "/testsetups/ts1/leaderboard",
            arenaSetupID: arena ? "ts1" : nil)
    }

    static var presentBoards: [(name: String, board: PresentModePresentation)] {
        [
            ("podium of ten", present(places: 10, window: window)),
            ("podium of two", present(places: 2, live: false)),
            ("podium of three, holder on it", present(places: 3, champion: 1, championOnPodium: true)),
            ("holder off the podium", present(places: 5, champion: 9)),
            ("empty", present()),
            ("empty with holder", present(champion: 1, live: false)),
            (
                "bracket complete",
                present(bracket: tournament(named: false, viewer: nil, complete: true), showsBracket: true, live: false)
            ),
            (
                "bracket running",
                present(
                    bracket: tournament(named: false, viewer: nil, complete: false), showsBracket: true, window: window)
            ),
            ("bracket none", present(showsBracket: true)),
            (
                "bracket in the arena",
                present(
                    bracket: tournament(named: false, viewer: nil, complete: false), showsBracket: true, arena: true)
            ),
            ("composite grid", presentComposite(.starter)),
            ("composite strip", presentComposite(sequenceSpec)),
        ]
    }

    // MARK: - The admin runner page

    struct Runner {
        let name: String
        let runner: AdminWorkerRow
        let tags: [String]
        let summary: AdminRunnerSummary
        let recentJobs: [AdminRunnerJobRow]
        let snapshots: [AdminRunnerSnapshotRow]
        let firstSeenAt: String?
        let chartBars: [AdminRunnerChartBar]
        let chartLabels: [String]
        let offlineForText: String

        func page(_ page: PageRequestContext) -> AdminRunnerPage {
            AdminRunnerPage(
                page: page, runner: runner, tags: tags, summary: summary, recentJobs: recentJobs, snapshots: snapshots,
                firstSeenAt: firstSeenAt, chartBars: chartBars, chartLabels: chartLabels, offlineForText: offlineForText
            )
        }
    }

    static func worker(offline: Bool, known: Bool) -> AdminWorkerRow {
        AdminWorkerRow(
            workerID: "runner-1", hostname: known ? "grader.example" : "", runnerVersion: known ? "0.5.3" : "",
            maxConcurrentJobs: 4, lastActive: "2026-10-12T10:00:00Z", assignedJobs: 1, jobsProcessed: 120,
            avgExecutionMs: nil, avgQueueWaitMs: nil, avgExecutionFormatted: nil, avgQueueWaitFormatted: nil,
            isOffline: offline)
    }

    static func summary(full: Bool) -> AdminRunnerSummary {
        AdminRunnerSummary(
            activeJobs: 1, maxJobs: 4, jobsProcessed: 120, avgExecutionFormatted: full ? "2s" : nil,
            avgQueueWaitFormatted: full ? "1s" : nil, avgOverheadFormatted: full ? "300ms" : nil,
            avgCacheAcquireFormatted: full ? "20ms" : nil, avgDownloadFormatted: full ? "100ms" : nil,
            avgPrepFormatted: full ? "50ms" : nil, cacheHitRateFormatted: full ? "80% (8/10)" : nil,
            passedCount: 7, failedCount: 2, errorCount: 1, timeoutCount: 1)
    }

    static func job(
        _ id: String, user: String?, status: String, completedAt: String?, limit: String = ""
    )
        -> AdminRunnerJobRow
    {
        var row = AdminRunnerJobRow(
            submissionID: id, assignmentID: nil, username: user, finalStatus: status, queueWaitMs: 1000,
            executionMs: 2000, queueWaitFormatted: "1s", executionFormatted: "2s", totalProcessingMs: 3000,
            totalProcessingFormatted: "3s", workdirPeakBytes: nil, workdirPeakFormatted: nil, completedAt: completedAt)
        if user != nil {
            row.avatar = avatar(UInt64(id.count))
        }
        let pill = AdminRoutes.statusPill(for: status)
        row.statusLabel = pill.label
        row.statusTier = pill.tier
        row.detailsText = user == nil ? "" : AdminRoutes.jobDetails(row)
        row.limitText = limit
        return row
    }

    static var runners: [Runner] {
        [
            Runner(
                name: "online with history", runner: worker(offline: false, known: true),
                tags: ["linux", "x86_64", "python 3.12"], summary: summary(full: true),
                recentJobs: [
                    job("sub-1", user: "ada", status: "passed", completedAt: "2026-10-12T09:00:00Z"),
                    job("sub-2", user: nil, status: "timeout", completedAt: nil, limit: "hit the 10s limit"),
                ],
                snapshots: [
                    AdminRunnerSnapshotRow(
                        recordedAt: "2026-10-12T09:00:00Z", activeJobs: 1, maxJobs: 4, activeJobsLabel: "1 / 4",
                        utilizationPercent: 25, lastPollAt: "2026-10-12T09:00:01Z"),
                    AdminRunnerSnapshotRow(
                        recordedAt: "2026-10-12T09:01:00Z", activeJobs: 0, maxJobs: 4, activeJobsLabel: "0 / 4",
                        utilizationPercent: 0, lastPollAt: nil),
                ],
                firstSeenAt: "2026-09-01T00:00:00Z",
                chartBars: [
                    AdminRunnerChartBar(heightPercent: 25, state: "busy", title: "09:00 · 1 / 4 · 25%"),
                    AdminRunnerChartBar(heightPercent: 2, state: "idle", title: "09:01 · 0 / 4 · 0%"),
                ],
                chartLabels: ["09:00", "09:01"], offlineForText: ""),
            Runner(
                name: "offline, nothing recorded", runner: worker(offline: true, known: false), tags: [],
                summary: summary(full: false), recentJobs: [], snapshots: [], firstSeenAt: nil, chartBars: [],
                chartLabels: [], offlineForText: "12m 3s"),
            Runner(
                name: "offline with a chart", runner: worker(offline: true, known: true), tags: [],
                summary: summary(full: false), recentJobs: [],
                snapshots: [
                    AdminRunnerSnapshotRow(
                        recordedAt: "2026-10-12T09:00:00Z", activeJobs: 4, maxJobs: 4, activeJobsLabel: "4 / 4",
                        utilizationPercent: 100, lastPollAt: nil)
                ],
                firstSeenAt: nil,
                chartBars: [AdminRunnerChartBar(heightPercent: 100, state: "full", title: "09:00 · 4 / 4 · 100%")],
                chartLabels: ["09:00"], offlineForText: ""),
        ]
    }
}
