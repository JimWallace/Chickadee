// APIServer/Routes/Web/ViewerIdentity.swift
//
// The viewer's own card on a class activity page: their handle and hero bird
// (`AvatarIdentity`), and the lines the card shares across kinds. Moved out
// of `WebRoutes+Leaderboard.swift` (#2720).

import Core
import Foundation

/// Who the viewer is to the page: their handle and hero bird, from the same
/// store every other row reads, and the lines a card shares across kinds.
struct ViewerIdentity {
    let handle: String
    let avatar: AvatarPresentation
    let privacyLine: String
    let submitURL: String

    /// nil when the viewer is not enrolled in the setup's course.
    static func load(viewer: APIUser, setup: APITestSetup, on db: any Database) async throws -> ViewerIdentity? {
        guard let viewerID = viewer.id,
            let identity = try await AvatarIdentity.load(userIDs: [viewerID], courseID: setup.courseID, on: db)
                .presentation(for: viewerID, includeName: false, fallbackLabel: "You", size: .hero, on: db)
        else { return nil }
        let handle = identity.handle
        return ViewerIdentity(
            handle: handle,
            avatar: identity.avatar,
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
            bestAtISO: best.reachedAt.map(iso8601String) ?? "",
            bestAtText: best.reachedAt.map(waterlooDateTimeFormatter().string(from:)) ?? "",
            nextPlaceText: best.nextPlaceText, hasNextPlace: !best.nextPlaceText.isEmpty,
            privacyLine: identity.privacyLine, submitURL: identity.submitURL)
    }
}
