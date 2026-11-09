// Tests/APITests/Guards/SchemaCatalog.swift
//
// The migrated schema as Postgres reports it, read from `pg_catalog` and
// `information_schema` in the test app's own schema (`current_schema()`).
// The database guards read this, not the migration sources: a scan of the
// Swift text cannot tell a column from a comment about one, and the catalog
// is what production runs on.

import ChickadeeTestSupport
import Fluent
import Foundation
import SQLKit
import Vapor

@testable import APIServer

/// One column of one table.
struct CatalogColumn: Sendable, Hashable {
    let table: String
    let name: String
    /// The `information_schema` type name, for example `text`, `uuid`,
    /// `bigint` or `timestamp with time zone`.
    let type: String
    let isNullable: Bool
    let hasDefault: Bool

    /// `table.column`, the form the allowlists use.
    var qualified: String { "\(table).\(name)" }
}

/// One single-column foreign key.
struct CatalogForeignKey: Sendable, Hashable {
    let table: String
    let column: String
    let referencedTable: String
    let name: String

    var qualified: String { "\(table).\(column)" }
}

/// One index, with its columns in key order. An expression index has an
/// empty column name in its place.
struct CatalogIndex: Sendable, Hashable {
    let table: String
    let name: String
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
    let isPartial: Bool
}

/// The tables, columns, foreign keys and indexes of the test app's schema.
/// Fluent's own bookkeeping tables (`_fluent_*`) are left out.
struct SchemaCatalog: Sendable {
    let columns: [CatalogColumn]
    let foreignKeys: [CatalogForeignKey]
    let indexes: [CatalogIndex]

    var tables: Set<String> { Set(columns.map(\.table)) }

    func columns(of table: String) -> [CatalogColumn] {
        columns.filter { $0.table == table }
    }

    func foreignKey(on table: String, column: String) -> CatalogForeignKey? {
        foreignKeys.first { $0.table == table && $0.column == column }
    }

    static func load(on db: any Database) async throws -> SchemaCatalog {
        guard let sql = db as? any SQLDatabase else {
            throw IssueRecorded("the test database is not an SQL database")
        }
        let columnRows = try await sql.raw(
            """
            SELECT c.table_name, c.column_name, c.data_type, c.is_nullable,
                   c.column_default IS NOT NULL AS has_default
            FROM information_schema.columns c
            JOIN information_schema.tables t
              ON t.table_schema = c.table_schema AND t.table_name = c.table_name
            WHERE c.table_schema = current_schema()
              AND t.table_type = 'BASE TABLE'
              AND c.table_name NOT LIKE '\\_fluent\\_%'
            ORDER BY c.table_name, c.ordinal_position
            """
        ).all()
        let columns = try columnRows.map { row in
            CatalogColumn(
                table: try row.decode(column: "table_name", as: String.self),
                name: try row.decode(column: "column_name", as: String.self),
                type: try row.decode(column: "data_type", as: String.self),
                isNullable: try row.decode(column: "is_nullable", as: String.self) == "YES",
                hasDefault: try row.decode(column: "has_default", as: Bool.self))
        }

        let keyRows = try await sql.raw(
            """
            SELECT cl.relname AS table_name, a.attname AS column_name,
                   rt.relname AS referenced_table, k.conname AS constraint_name,
                   array_length(k.conkey, 1) AS width
            FROM pg_constraint k
            JOIN pg_class cl ON cl.oid = k.conrelid
            JOIN pg_class rt ON rt.oid = k.confrelid
            JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
            WHERE k.contype = 'f' AND cl.relnamespace = current_schema()::regnamespace
              AND cl.relname NOT LIKE '\\_fluent\\_%'
            ORDER BY 1, 2
            """
        ).all()
        let foreignKeys = try keyRows.map { row in
            let width = try row.decode(column: "width", as: Int.self)
            let name = try row.decode(column: "constraint_name", as: String.self)
            guard width == 1 else {
                throw IssueRecorded("foreign key \(name) spans \(width) columns; SchemaCatalog reads one")
            }
            return CatalogForeignKey(
                table: try row.decode(column: "table_name", as: String.self),
                column: try row.decode(column: "column_name", as: String.self),
                referencedTable: try row.decode(column: "referenced_table", as: String.self),
                name: name)
        }

        let indexRows = try await sql.raw(
            """
            SELECT cl.relname AS table_name, ic.relname AS index_name,
                   i.indisunique AS is_unique, i.indisprimary AS is_primary,
                   i.indpred IS NOT NULL AS is_partial,
                   array_to_string(ARRAY(
                     SELECT coalesce(a.attname, '')
                     FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, position)
                     LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                     ORDER BY k.position
                   ), ',') AS columns
            FROM pg_index i
            JOIN pg_class cl ON cl.oid = i.indrelid
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE cl.relnamespace = current_schema()::regnamespace
              AND cl.relname NOT LIKE '\\_fluent\\_%'
            ORDER BY 1, 2
            """
        ).all()
        let indexes = try indexRows.map { row in
            CatalogIndex(
                table: try row.decode(column: "table_name", as: String.self),
                name: try row.decode(column: "index_name", as: String.self),
                columns: try row.decode(column: "columns", as: String.self)
                    .split(separator: ",", omittingEmptySubsequences: false).map(String.init),
                isUnique: try row.decode(column: "is_unique", as: Bool.self),
                isPrimary: try row.decode(column: "is_primary", as: Bool.self),
                isPartial: try row.decode(column: "is_partial", as: Bool.self))
        }
        return SchemaCatalog(columns: columns, foreignKeys: foreignKeys, indexes: indexes)
    }
}
