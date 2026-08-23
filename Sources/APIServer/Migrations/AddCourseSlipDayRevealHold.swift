// APIServer/Migrations/AddCourseSlipDayRevealHold.swift
//
// Course-level opt-out for the release-output slip-day reveal hold
// (`SlipDayPolicy.releaseRevealHold`).  Nullable so every existing course
// decodes as "hold on" — the safe direction, and the behaviour the hold's
// introduction established.
//
// Fold into CreateCourses in the next consolidation round once every
// deployment has verifiably applied it.

import Fluent

struct AddCourseSlipDayRevealHold: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("slip_day_release_reveal_hold", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("slip_day_release_reveal_hold")
            .update()
    }
}
