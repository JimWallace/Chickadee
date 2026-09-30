// APIServer/Migrations/SwapStarterGradcapForHeadband.swift
//
// One-time swap of every stored gradcap for the headband
// (docs/student-wardrobe.md, decision 4).
//
// The gradcap reads as "graduated", so it left the first-use draw to become a
// completion item later. The maintainer chose to swap the gradcaps already
// drawn as well, so that the gradcap means completion from the first day. This
// is the one place where a stored bird changes after it was drawn, and only its
// accessory changes.
//
// It is a migration and not a rule in `AvatarStore.ensureSpec` on purpose: a
// migration runs once, so a gradcap a student EARNS later is never taken away.
// Nobody can earn one yet, so every gradcap stored now came from the draw.
//
// Raw SQL rather than a model query, so the migration does not depend on the
// columns `APIUser` gains in later migrations (the #1077 boot-order hazard).

import Core
import Fluent
import Foundation
import SQLKit

struct SwapStarterGradcapForHeadband: ChickadeeMigration {

    private struct Row: Decodable {
        let id: UUID
        let avatarSpec: String

        enum CodingKeys: String, CodingKey {
            case id
            case avatarSpec = "avatar_spec"
        }
    }

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        let rows = try await sql.select()
            .columns("id", "avatar_spec")
            .from("users")
            .where("avatar_spec", .like, "%gradcap%")
            .all(decoding: Row.self)

        var swapped = 0
        for row in rows {
            guard let spec = AvatarStore.decode(row.avatarSpec), spec.accessory == .gradcap,
                let json = AvatarStore.encode(Self.swapped(spec))
            else { continue }
            try await sql.update("users")
                .set("avatar_spec", to: json)
                .where("id", .equal, row.id)
                .run()
            swapped += 1
        }
        database.logger.info("avatar: swapped \(swapped) starter gradcap(s) for the headband")
    }

    /// Nothing to undo: the gradcap was not an earned choice, and restoring it
    /// would need a record of who had one, which the swap does not keep.
    func revert(on database: Database) async throws {}

    /// `spec` with its gradcap replaced by the headband; every other slot as it
    /// was.
    static func swapped(_ spec: AvatarSpec) -> AvatarSpec {
        var updated = spec
        if updated.accessory == .gradcap { updated.accessory = .headband }
        return updated
    }
}
