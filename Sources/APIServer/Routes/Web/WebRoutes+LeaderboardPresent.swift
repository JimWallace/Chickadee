// APIServer/Routes/Web/WebRoutes+LeaderboardPresent.swift
//
// GET /testsetups/:testSetupID/leaderboard?present=1 — the leaderboard for a
// projector (docs/class-activities.md). Course staff only.
//
// A projected page is read by the whole room, so every presentation here is
// built WITHOUT names, whoever is viewing: the handle and the bird are the
// identity, and a student sees their own bird on the wall. A staff member who
// wants the mapping reads the ordinary page.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    /// Renders Present mode. The caller has already checked that the viewer is
    /// course staff and that the setup has a leaderboard activity.
    func leaderboardPresentPage(
        req: Request, user: APIUser, setup: APITestSetup, activity: ClassActivity
    ) async throws -> Response {
        let setupID = setup.id ?? ""
        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        let course = try await APICourse.find(setup.courseID, on: req.db)
        let aggregation = activity.kind.aggregation

        // Nameless like a student view, locking no handle like a staff one.
        // Staff decide what they project and when, and opening the page to
        // check it must not spend every student's one change (#1757).
        let reader = LeaderboardReader.presenting(as: user)
        var places: [PresentPlace] = []
        let title: String
        var tournament: TournamentPresentation?
        switch aggregation {
        case .standings:
            let board = try await buildStandingsBoard(
                setup: setup, reader: reader, showAll: true, on: req.db)
            places = board.rows.map {
                PresentPlace(
                    rank: $0.rank, rankText: $0.rankText, rankTier: $0.rankTier, handle: $0.handle,
                    valueText: $0.valueText, avatar: $0.avatar)
            }
            title = "Standings · highest average"
        case .union:
            let union = try await buildUnionPresentation(
                setup: setup, reader: reader, showAll: true, allURL: "", on: req.db)
            places = (union?.kills ?? []).map {
                PresentPlace(
                    rank: $0.rank, rankText: $0.rankText, rankTier: $0.rankTier, handle: $0.handle,
                    valueText: $0.valueText, avatar: $0.avatar)
            }
            title = "Tests · most faults found"
        case .bracket:
            tournament = try await buildTournamentPresentation(
                setup: setup, viewerID: nil, includeNames: false, on: req.db)
            // A title is a noun phrase; where the run stands goes in the clock's place.
            title = tournament.map { "Tournament · \($0.scheduleName.lowercased())" } ?? "Tournament"
        case .composite:
            // A composite ranks nobody: the composed image takes the
            // podium's place (docs/class-composite.md).
            title = "Class composite"
        case .leaderboard:
            // Named rather than left to a catch-all arm, so a fifth
            // aggregation does not render the metric board silently (#1745).
            let board = try await buildLeaderboard(
                setup: setup, reader: reader, showAll: true, on: req.db)
            places = board.rows.map {
                PresentPlace(
                    rank: $0.rank, rankText: $0.rankText, rankTier: $0.rankTier, handle: $0.handle,
                    valueText: $0.metricText, avatar: $0.avatar)
            }
            title = "Leaderboard · highest metric"
        }
        let champion = try await buildChampionPresentation(
            setup: setup, activity: activity, viewerID: nil, includeNames: false, on: req.db)
        // The hill's holder is not always first on the metric board, so the
        // kicker goes on the place that holds it. A handle names one student
        // in a course; an empty one (an exhausted handle space) matches none.
        if let champion, !champion.handle.isEmpty {
            places = places.map { place in
                var place = place
                place.isChampion = place.handle == champion.handle
                return place
            }
        }
        let compositeProgress = try await compositeProgress(
            setup: setup, activity: activity, assignment: assignment, on: req.db)
        let podium = PresentPlace.podiumOrder(places)
        let winner = tournament?.winner

        let boardURL = "/testsetups/\(setupID)/leaderboard"
        let session = LiveSessionPresentation.make(activity)
        let presentation = PresentModePresentation(
            testSetupID: setupID,
            assignmentTitle: assignment?.title ?? setupID,
            courseCode: course?.code ?? "",
            title: title,
            podium: podium,
            hasPodium: !places.isEmpty,
            rest: Array(places.dropFirst(3).prefix(7)),
            rankedCount: places.count,
            showsBracket: aggregation == .bracket,
            hasTournament: tournament != nil,
            tournament: tournament,
            entrantCount: tournament.map(Self.entrantCount) ?? 0,
            hasWinner: winner?.avatar != nil,
            winnerHandle: winner?.handle ?? "",
            winnerAvatar: winner?.avatar?.resized(to: .hero),
            hasChampion: champion != nil,
            championHandle: champion?.handle ?? "",
            championAvatar: champion?.avatar,
            championOnPodium: podium.contains(where: \.isChampion),
            hasWindow: session != nil,
            window: session,
            // A composite's progress shows beside its clock: it is the run's
            // whole state, with or without a window.
            hasProgress: compositeProgress != nil || (session == nil && tournament != nil),
            progressLabel: compositeProgress?.label ?? tournament?.progressLabel ?? "",
            progressValue: compositeProgress?.value ?? tournament?.progressValue ?? "",
            // A finished tournament cannot change, so its wall stops saying Live.
            pollsLive: tournament?.isComplete != true
                && (activity.window.map { $0.state(at: Date()) != .afterClose } ?? true),
            pollURL: "\(boardURL)?present=1&fragment=present",
            boardURL: boardURL,
            arenaSetupID: aggregation == .bracket && playsInArena(setup) ? setupID : nil,
            compositeStage: compositeProgress?.stage)

        // `?fragment=present` renders the SAME view the page renders inline,
        // so the refresh cannot drift from what it replaces.
        guard req.query[String.self, at: "fragment"] == "present" else {
            return try await HTMLResponse {
                LeaderboardPresentPage(page: PageRequestContext(request: req), board: presentation)
            }
            .encodeResponse(for: req)
        }
        let html = LeaderboardPresentBody(board: presentation).render()
        return Response.pollFragment(html: html, for: req)
    }

    /// A class composite's stage, and its progress for the clock's place:
    /// "Tiles complete" over "31 of 48". Nil on every other kind.
    private func compositeProgress(
        setup: APITestSetup, activity: ClassActivity, assignment: APIAssignment?, on db: any Database
    ) async throws -> (stage: CompositeStagePresentation, label: String, value: String)? {
        guard activity.kind == .classComposite, let spec = activity.composite, let assignmentID = assignment?.id,
            let setupID = setup.id
        else { return nil }
        let snapshot = try await CompositeSnapshot.build(
            .init(assignmentID: assignmentID, testSetupID: setupID, courseID: setup.courseID, spec: spec),
            since: .max, onlyUserID: nil, includeOwners: false, on: db)
        let noun = spec.compositor.slotNoun
        let label = "\(noun.prefix(1).uppercased())\(noun.dropFirst()) complete"
        let stage = CompositeStagePresentation.board(
            spec: spec, testSetupID: setupID, present: true, pollUntilISO: activity.window?.closesAtISO)
        return (stage, label, "\(snapshot.complete) of \(snapshot.total)")
    }

    /// Everyone seeded into the run. A bye is a match with one entrant, so
    /// counting distinct seeds over every match counts each entrant once.
    static func entrantCount(_ tournament: TournamentPresentation) -> Int {
        let seeds = tournament.rounds.flatMap(\.matches).flatMap { [$0.home?.seed, $0.away?.seed] }
        return Set(seeds.compactMap(\.self)).count
    }
}

/// One place on the wall: a handle, a bird and the value it is ranked on.
struct PresentPlace: Encodable, Sendable {
    let rank: Int
    let rankText: String
    let rankTier: String
    let handle: String
    let valueText: String
    let avatar: AvatarPresentation
    /// True on the place that holds the hill; set after the places are built.
    var isChampion = false

    /// The first three places in podium order — second, first, third — so the
    /// winner stands in the middle. Fewer than three places keep the same
    /// order with the missing ones left out.
    static func podiumOrder(_ places: [PresentPlace]) -> [PresentPlace] {
        let top = Array(places.prefix(3))
        switch top.count {
        case 3: return [top[1], top[0], top[2]]
        case 2: return [top[1], top[0]]
        default: return top
        }
    }
}

/// Everything Present mode shows. `LeaderboardPresentPage` draws the fixed
/// chrome from it, and `LeaderboardPresentBody` the part that moves, inline
/// and again as the `?fragment=present` refresh.
struct PresentModePresentation {
    let testSetupID: String
    let assignmentTitle: String
    let courseCode: String
    /// "Leaderboard · highest metric".
    let title: String
    let podium: [PresentPlace]
    let hasPodium: Bool
    /// Places four to ten.
    let rest: [PresentPlace]
    let rankedCount: Int
    let showsBracket: Bool
    let hasTournament: Bool
    let tournament: TournamentPresentation?
    /// Everyone in the run, for the footer's count.
    let entrantCount: Int
    /// The tournament's winner at the champion card's size. False for a winner with no
    /// bird (a dropped student), whom the bracket names by seed.
    let hasWinner: Bool
    let winnerHandle: String
    let winnerAvatar: AvatarPresentation?
    /// The hill's holder, named by handle only.
    let hasChampion: Bool
    let championHandle: String
    let championAvatar: AvatarPresentation?
    /// True when the holder stands on the podium and so carries its kicker
    /// there; false puts them on a card of their own above the stage.
    let championOnPodium: Bool
    let hasWindow: Bool
    let window: LiveSessionPresentation?
    /// A tournament with no session window shows where the run stands in the
    /// clock's place.
    let hasProgress: Bool
    let progressLabel: String
    let progressValue: String
    let pollsLive: Bool
    let pollURL: String
    let boardURL: String
    /// The setup the projector arena plays, set on a browser-graded
    /// tournament only (docs/class-activities.md, "Projector arena").
    let arenaSetupID: String?
    /// A class composite's stage, in the podium's place; nil on every other
    /// kind.
    var compositeStage: CompositeStagePresentation?
}
