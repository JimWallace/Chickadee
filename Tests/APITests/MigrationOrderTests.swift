// Tests/APITests/MigrationOrderTests.swift
//
// Two kinds of data migration depend on where they sit in `registerMigrations`
// (#1805), and the comments that used to guard the order had gone stale:
//
// - A migration that full-queries a model (`Model.query(on:)`) selects every
//   column the model declares. It must follow every migration that changes the
//   model's table, or a fresh boot selects a column that does not exist yet
//   (the #1077 boot-order hazard).
// - A raw-SQL migration that reads a column must follow the migration that
//   adds the column.
//
// Both rules are read from the source, so a migration appended in the wrong
// place fails here the day it lands, not on the next fresh boot.

import Foundation
import Testing

@Suite struct MigrationOrderTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // APITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The registered migration types, in order. Vapor's own
    /// `SessionRecord.migration` is not a type of ours and is not listed.
    private static func registeredMigrations() throws -> [String] {
        let source = try read("Sources/APIServer/Bootstrap/DatabaseConfiguration.swift")
        let start = try #require(source.range(of: "func registerMigrations("))
        let body = source[start.upperBound...]
        let pattern = try Regex(#"app\.migrations\.add\(([A-Za-z]+)\("#)
        return body.matches(of: pattern).compactMap { match in
            match.output[1].substring.map(String.init)
        }
    }

    private static func migrationSource(_ name: String) throws -> String {
        try read("Sources/APIServer/Migrations/\(name).swift")
    }

    /// The models a migration full-queries.
    private static func queriedModels(in source: String) throws -> Set<String> {
        let pattern = try Regex(#"([A-Za-z]+)\.query\(on:"#)
        return Set(source.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) })
    }

    /// The table a model declares with `static let schema`.
    private static func table(of model: String) throws -> String? {
        let source = try read("Sources/APIServer/Models/\(model).swift")
        let pattern = try Regex(#"static let schema = "([a-z_]+)""#)
        return source.firstMatch(of: pattern)?.output[1].substring.map(String.init)
    }

    /// The columns a raw-SQL migration selects, from its `.columns(...)` calls.
    private static func selectedColumns(in source: String) throws -> Set<String> {
        let call = try Regex(#"\.columns\(([^)]*)\)"#)
        let name = try Regex(#""([a-z_]+)""#)
        var columns: Set<String> = []
        for match in source.matches(of: call) {
            guard let arguments = match.output[1].substring else { continue }
            for column in arguments.matches(of: name) {
                if let value = column.output[1].substring { columns.insert(String(value)) }
            }
        }
        return columns
    }

    @Test func theListIsReadInFull() throws {
        let names = try Self.registeredMigrations()
        // A parse that stopped early would make the two rules below pass
        // vacuously, so check that it found the list's two ends.
        #expect(names.first == "CreateUsers")
        #expect(names.count > 60)
        for name in names {
            #expect(
                FileManager.default.fileExists(
                    atPath: Self.repoRoot.appendingPathComponent("Sources/APIServer/Migrations/\(name).swift").path),
                "no source file for \(name)")
        }
    }

    @Test func aMigrationThatQueriesAModelFollowsEveryChangeToItsTable() throws {
        let names = try Self.registeredMigrations()
        var checked = 0
        for (index, name) in names.enumerated() {
            for model in try Self.queriedModels(in: try Self.migrationSource(name)) {
                let declared = try Self.table(of: model)
                let table = try #require(declared, "\(model) declares no schema")
                for later in names[(index + 1)...] {
                    #expect(
                        !(try MigrationSourceScan.tables(in: try Self.migrationSource(later))).contains(table),
                        "\(later) changes \(table) after \(name) full-queries \(model)")
                }
                checked += 1
            }
        }
        // BackfillDeclaredLanguage and BackfillSharedSupportFiles.
        #expect(checked >= 2)
    }

    @Test func aRawSQLMigrationFollowsTheMigrationThatAddsEachColumnItReads() throws {
        let names = try Self.registeredMigrations()
        let sources = try names.map(Self.migrationSource)
        var checked = 0
        for (index, source) in sources.enumerated() where source.contains("sql.select()") {
            for column in try Self.selectedColumns(in: source) where column != "id" {
                let marker = ".field(\"\(column)\""
                let adder = sources.firstIndex { $0.contains(marker) }
                #expect(adder != nil, "no migration adds \(column), which \(names[index]) reads")
                if let adder {
                    #expect(adder < index, "\(names[index]) reads \(column) before \(names[adder]) adds it")
                }
                checked += 1
            }
        }
        // SwapStarterGradcapForHeadband and FillLateAvatarAxes read avatar_spec.
        #expect(checked >= 2)
    }
}
