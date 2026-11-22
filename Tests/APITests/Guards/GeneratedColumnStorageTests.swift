// Tests/APITests/Guards/GeneratedColumnStorageTests.swift
//
// Every generated column is STORED, unless it is on the list below with a
// reason. From PostgreSQL 18, `GENERATED ALWAYS AS (…)` with no storage
// keyword makes a VIRTUAL column: it is computed on every read, and it cannot
// be indexed, be part of a unique constraint or foreign key, or use a
// user-defined function. A migration that means STORED but leaves out the word
// still builds, and the cost shows only on the hot path that reads it.
//
// A new generated column fails this test until it says STORED or gets a
// reason on the list.

import ChickadeeTestSupport
import Fluent
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
struct GeneratedColumnStorageTests {

    /// "table.column" generated columns that are VIRTUAL on purpose, each with
    /// its reason. Empty: the schema has no generated column yet.
    static let virtualOnPurpose: Set<String> = []

    @Test func everyGeneratedColumnIsStored() async throws {
        try await withTestApp { app in
            guard let sql = app.db as? any SQLDatabase else {
                throw IssueRecorded("the test database is not an SQL database")
            }
            // `attgenerated` is 's' for STORED and 'v' for VIRTUAL (18+).
            let rows = try await sql.raw(
                """
                SELECT cl.relname AS table_name, a.attname AS column_name
                FROM pg_attribute a
                JOIN pg_class cl ON cl.oid = a.attrelid
                WHERE cl.relnamespace = current_schema()::regnamespace
                  AND cl.relkind IN ('r', 'p')
                  AND a.attnum > 0 AND NOT a.attisdropped
                  AND a.attgenerated = 'v'
                ORDER BY 1, 2
                """
            ).all()
            let virtual = try rows.map { row in
                "\(try row.decode(column: "table_name", as: String.self))."
                    + (try row.decode(column: "column_name", as: String.self))
            }
            let unexpected = virtual.filter { !Self.virtualOnPurpose.contains($0) }
            #expect(
                unexpected.isEmpty,
                """
                VIRTUAL generated columns: \(unexpected.joined(separator: ", ")). PostgreSQL 18 makes a \
                generated column VIRTUAL when the migration does not say STORED. Write \
                GENERATED ALWAYS AS (…) STORED, or add the column to virtualOnPurpose with a reason.
                """)
            let stale = Self.virtualOnPurpose.subtracting(virtual)
            #expect(stale.isEmpty, "virtualOnPurpose names columns that are not VIRTUAL: \(stale.sorted())")
        }
    }
}
