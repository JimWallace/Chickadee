// APIServer/Routes/Web/BoardIdentities.swift
//
// Where a ranking board reads its students' handles and birds: loaded for
// this request (`AvatarIdentity`), or a snapshot shared by every refresh of
// the same board (`RosterSnapshot`, docs/live-board-cache.md).

import Core
import Fluent
import Foundation

protocol BoardIdentities {
    /// False for a student who has since dropped.
    func isOnRoster(_ userID: UUID) -> Bool

    /// The handle-and-bird presentation of a student; nil when
    /// `isOnRoster` is false.
    func presentation(
        for userID: UUID, includeName: Bool, fallbackLabel: String, size: AvatarSize, on db: any Database
    ) async throws -> AvatarIdentity.Presentation?

    /// The username a staff row shows.
    func username(of userID: UUID) -> String?
}
