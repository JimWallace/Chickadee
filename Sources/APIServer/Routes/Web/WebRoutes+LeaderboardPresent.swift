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

        // `isStaff: false` buys the nameless rendering; `lockingFor: nil`
        // keeps it a staff view, which locks no handle. Staff decide what
        // they project and when, and opening the page to check it must not
        // spend every student's one change (#1757).
        var places: [PresentPlace] = []
        var valueLabel = "metric"
        var tournament: TournamentPresentation?
        switch aggregation {
        case .standings:
            let board = try await buildStandingsBoard(
                setup: setup, viewer: user, isStaff: false, lockingFor: nil, showAll: true, on: req.db)
            places = board.rows.map {
                PresentPlace(
                    rank: $0.rank, rankText: $0.rankText, rankTier: $0.rankTier, handle: $0.handle,
                    valueText: $0.valueText, avatar: $0.avatar)
            }
            valueLabel = "average"
        case .union:
            let union = try await buildUnionPresentation(
                setup: setup, viewer: user, isStaff: false, lockingFor: nil, showAll: true, allURL: "",
                on: req.db)
            places = (union?.kills ?? []).map {
                PresentPlace(
                    rank: $0.rank, rankText: $0.rankText, rankTier: $0.rankTier, handle: $0.handle,
                    valueText: $0.valueText, avatar: $0.avatar)
            }
            valueLabel = "faults"
        case .bracket:
            tournament = try await buildTournamentPresentation(
                setup: setup, viewerID: nil, includeNames: false, on: req.db)
        case .leaderboard:
            // Named rather than left to a catch-all arm, so a fifth
            // aggregation does not render the metric board silently (#1745).
            let board = try await buildLeaderboard(
                setup: setup, viewer: user, isStaff: false, lockingFor: nil, showAll: true, on: req.db)
            places = board.rows.map {
                PresentPlace(
                    rank: $0.rank, rankText: $0.rankText, rankTier: $0.rankTier, handle: $0.handle,
                    valueText: $0.metricText, avatar: $0.avatar)
            }
        }
        let champion = try await buildChampionPresentation(
            setup: setup, activity: activity, viewerID: nil, includeNames: false, on: req.db)

        let boardURL = "/testsetups/\(setupID)/leaderboard"
        let session = LiveSessionPresentation.make(activity)
        let context = LeaderboardPresentContext(
            testSetupID: setupID,
            assignmentTitle: assignment?.title ?? setupID,
            courseCode: course?.code ?? "",
            title: "Leaderboard · highest \(valueLabel)",
            podium: PresentPlace.podiumOrder(places),
            hasPodium: !places.isEmpty,
            rest: Array(places.dropFirst(3).prefix(7)),
            rankedCount: places.count,
            showsBracket: aggregation == .bracket,
            hasTournament: tournament != nil,
            tournament: tournament,
            hasChampion: champion != nil,
            championHandle: champion?.handle ?? "",
            hasWindow: session != nil,
            window: session,
            pollsLive: activity.window.map { $0.state(at: Date()) != .afterClose } ?? true,
            pollURL: "\(boardURL)?present=1&fragment=present",
            boardURL: boardURL)

        guard req.query[String.self, at: "fragment"] == "present" else {
            return try await req.view.render("leaderboard-present", context).encodeResponse(for: req)
        }
        return try await req.view.render("_leaderboard-present-body", context)
            .encodePollFragment(for: req)
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

struct LeaderboardPresentContext: Encodable {
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
    /// The hill's holder, named by handle only.
    let hasChampion: Bool
    let championHandle: String
    let hasWindow: Bool
    let window: LiveSessionPresentation?
    let pollsLive: Bool
    let pollURL: String
    let boardURL: String
}
