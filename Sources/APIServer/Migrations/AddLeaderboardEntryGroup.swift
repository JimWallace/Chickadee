// APIServer/Migrations/AddLeaderboardEntryGroup.swift
//
// `leaderboard_entries.group_id`: the lab group whose session a ranked result
// was played in (docs/lab-groups.md, slice 3). Optional: an activity that does
// not run per group, and every row made before the column, has none. No
// foreign key: a group is removed by `removed_at`, never by a delete, and a
// course's delete takes its setups' rows with it.

import Fluent

struct AddLeaderboardEntryGroup: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APILeaderboardEntry.schema)
            .field("group_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APILeaderboardEntry.schema)
            .deleteField("group_id")
            .update()
    }
}
