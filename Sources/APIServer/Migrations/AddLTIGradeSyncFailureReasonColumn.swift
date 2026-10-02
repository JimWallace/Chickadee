// APIServer/Migrations/AddLTIGradeSyncFailureReasonColumn.swift
//
// `lti_grade_syncs.failure_reason`: why the last push failed, as a code
// (`LTIGradeSyncFailureReason`). The queue used to key its retry-on-launch
// rule on the stored sentence, so rewording the sentence changed behaviour
// (#1652). Rows that had failed because the student had not launched get the
// code, so their retry still happens.

import Fluent
import SQLKit

struct AddLTIGradeSyncFailureReasonColumn: ChickadeeMigration {
    /// The sentence the sweep stored on the day those rows were written.
    /// FROZEN on purpose: the backfill must match what is in the table, not
    /// what the sweep says today. It must never track
    /// `LTIGradeSyncSweep.notLaunchedMessage`, or rewording that sentence
    /// before a database applies this migration silently backfills nothing
    /// (#1811).
    static let storedNotLaunchedMessage = "The student has not opened Chickadee from the LMS yet."

    func prepare(on database: Database) async throws {
        try await database.schema("lti_grade_syncs").field("failure_reason", .string).update()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "UPDATE lti_grade_syncs SET failure_reason = \(bind: LTIGradeSyncFailureReason.notLaunched.rawValue) WHERE error = \(bind: Self.storedNotLaunchedMessage)"
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lti_grade_syncs").deleteField("failure_reason").update()
    }
}
