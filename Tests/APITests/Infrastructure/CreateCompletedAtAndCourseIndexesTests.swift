// Tests/APITests/Infrastructure/CreateCompletedAtAndCourseIndexesTests.swift
//
// The three indexes of #2778 exist after migration, on the named table and
// column.

import Fluent
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CreateCompletedAtAndCourseIndexesTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-idx-2778")
    }

    /// Index name, table, and the one column it covers.
    static let expected: [(name: String, table: String, column: String)] = [
        ("idx_job_execution_metrics_completed_at", "job_execution_metrics", "completed_at"),
        ("idx_course_sections_course_id", "course_sections", "course_id"),
        ("idx_course_content_items_course_id", "course_content_items", "course_id"),
    ]

    @Test func eachIndexExistsOnItsColumn() async throws {
        try await withApp(app) { app in
            let sql = try #require(app.db as? any SQLDatabase)
            for index in Self.expected {
                let columns = try await Self.indexedColumns(of: index.name, on: index.table, sql: sql)
                #expect(columns == [index.column], "\(index.name): \(columns)")
            }
        }
    }

    /// The columns an index covers, in order; empty when the index is absent.
    private static func indexedColumns(
        of name: String, on table: String, sql: any SQLDatabase
    ) async throws -> [String] {
        let rows = try await sql.raw(
            """
            SELECT a.attname AS name
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_class t ON t.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(i.indkey)
            WHERE c.relname = \(bind: name) AND t.relname = \(bind: table)
              AND n.nspname = current_schema()
            ORDER BY a.attnum
            """
        ).all()
        return try rows.map { try $0.decode(column: "name", as: String.self) }
    }
}
