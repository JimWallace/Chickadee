import Fluent

/// Adds disk-usage telemetry columns to both `submission_diagnostics`
/// (the 1:1 legacy mirror) and `job_execution_metrics` (the canonical
/// v0.4.46 table). `workdir_peak_bytes` is a bigint because workspace
/// sizes can exceed Int32 on larger assignments; the MB columns stay
/// `int` since 2 GB is well past any realistic free-disk reading.
struct AddJobDiskUsageMetrics: AsyncMigration {
    private static let intFields: [String] = [
        "free_disk_mb_at_start",
        "free_disk_mb_at_end",
    ]
    private static let bigIntFields: [String] = [
        "workdir_peak_bytes"
    ]

    func prepare(on database: Database) async throws {
        for schemaName in [JobExecutionMetric.schema, APISubmissionDiagnostics.schema] {
            for field in Self.intFields {
                try await database.schema(schemaName)
                    .field(FieldKey(stringLiteral: field), .int)
                    .update()
            }
            for field in Self.bigIntFields {
                try await database.schema(schemaName)
                    .field(FieldKey(stringLiteral: field), .int64)
                    .update()
            }
        }
    }

    func revert(on database: Database) async throws {
        for schemaName in [JobExecutionMetric.schema, APISubmissionDiagnostics.schema] {
            for field in Self.intFields + Self.bigIntFields {
                try await database.schema(schemaName)
                    .deleteField(FieldKey(stringLiteral: field))
                    .update()
            }
        }
    }
}
