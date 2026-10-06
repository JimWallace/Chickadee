// APIServer/Migrations/FillLateAvatarAxes.swift
//
// One-time fill of the tuft and tilt axes for every bird stored before those
// axes existed (docs/student-avatars.md, decision 2).
//
// A spec saved before the tune-up has no key for either axis, which is
// different from a student whose draw gave them `none` and `upright`. Decoding
// such a spec fills the defaults, so without this every student who predates
// the axes would stay tuftless and upright: a cohort their classmates could
// see. The fill draws ONLY the missing axes, so every slot the student already
// had stays as it was.
//
// A migration rather than a rule in `AvatarStore.ensureSpec` (#1762): the fill
// is one change to stored data, and a migration runs it once over every row
// instead of once per student on an account-page load, with no probe on every
// read afterwards. `SwapStarterGradcapForHeadband` made the same choice.
//
// Raw SQL rather than a model query, so the migration does not depend on the
// columns `APIUser` gains in later migrations (the #1077 boot-order hazard).

import Core
import Fluent
import Foundation
import SQLKit

struct FillLateAvatarAxes: ChickadeeMigration {

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
            .where("avatar_spec", .isNot, SQLLiteral.null)
            .all(decoding: Row.self)

        var filled = 0
        for row in rows {
            let missing = AvatarSpec.missingAxes(inStoredJSON: row.avatarSpec)
            guard !missing.isEmpty, let spec = AvatarStore.decode(row.avatarSpec),
                let json = AvatarStore.encode(spec.fillingMissing(missing))
            else { continue }
            try await sql.update("users")
                .set("avatar_spec", to: json)
                .where("id", .equal, row.id)
                .run()
            filled += 1
        }
        database.logger.info("avatar: filled the late axes of \(filled) bird(s)")
    }

    /// Nothing to undo: the drawn values are indistinguishable from a draw that
    /// happened on the first view.
    func revert(on database: Database) async throws {}
}
