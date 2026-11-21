// Tests/APITests/Guards/APITestsLayoutTests.swift
//
// The layout of this test target: each suite lives in a feature folder, and
// the top level holds only the helpers that several folders share. A suite
// added at the top level would start the flat directory again, so it fails
// here. The folders themselves are the ones that the "APITests is grouped by
// feature" bullet of docs/testing-conventions.md names, so a new folder, or a
// folder that goes away, changes that list in the same pull request.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct APITestsLayoutTests {

    private static let root = repositoryRoot.appendingPathComponent("Tests/APITests")
    private static let conventions = repositoryRoot.appendingPathComponent("docs/testing-conventions.md")

    /// The folders that hold helpers and no suite. The doc names each one in
    /// the sentence that starts "One folder holds helpers and no suite:".
    private static let helperFolders: Set<String> = ["PageFixtures"]

    /// True when the Swift file at `url` declares a test.
    private static func declaresATest(_ url: URL) throws -> Bool {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("@Test")
        }
    }

    /// The immediate sub-folders of `Tests/APITests`.
    private static func folders() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return try Set(
            names.filter { name in
                let values = try root.appendingPathComponent(name).resourceValues(forKeys: [.isDirectoryKey])
                return values.isDirectory == true
            })
    }

    /// The text of the "APITests is grouped by feature" bullet, its lines
    /// joined by spaces. The bullet runs from its bold lead-in to the next
    /// line that starts another bullet or is blank.
    private static func layoutBullet() throws -> String {
        let lines = try String(contentsOf: conventions, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false)
        let start = try #require(
            lines.firstIndex { $0.hasPrefix("- **APITests is grouped by feature.**") },
            "docs/testing-conventions.md has no \"APITests is grouped by feature\" bullet")
        var bullet = [String(lines[start])]
        for line in lines[(start + 1)...] {
            if line.hasPrefix("- ") || line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            bullet.append(line.trimmingCharacters(in: .whitespaces))
        }
        return bullet.joined(separator: " ")
    }

    /// The backticked names in the sentence of `text` that starts right after
    /// `lead`, up to the full stop that ends it.
    private static func backtickedNames(after lead: String, in text: String) throws -> [String] {
        let start = try #require(text.range(of: lead), "the bullet has no \"\(lead)\"")
        let rest = text[start.upperBound...]
        let sentence = rest.range(of: ". ").map { rest[..<$0.lowerBound] } ?? rest
        return sentence.matches(of: /`([^`]+)`/).map { String($0.output.1) }
    }

    @Test func theTopLevelHoldsSharedHelpersOnly() throws {
        let topLevel = try FileManager.default.contentsOfDirectory(atPath: Self.root.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(topLevel.count > 10, "sanity: the helpers were found")

        let suites = try topLevel.filter { name in
            try Self.declaresATest(Self.root.appendingPathComponent(name))
        }
        #expect(suites.isEmpty, "move these into a feature folder: \(suites.sorted())")
    }

    @Test func aHelperFolderHoldsNoSuite() throws {
        for folder in Self.helperFolders.sorted() {
            let url = Self.root.appendingPathComponent(folder)
            let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".swift") }
            #expect(!files.isEmpty, "sanity: \(folder) holds the helpers")
            let suites = try files.filter { try Self.declaresATest(url.appendingPathComponent($0)) }
            #expect(suites.isEmpty, "move these out of the helper folder \(folder): \(suites.sorted())")
        }
    }

    @Test func theFoldersAreTheOnesTheConventionsDocNames() throws {
        let bullet = try Self.layoutBullet()
        let features = try Self.backtickedNames(after: "the feature it covers:", in: bullet)
        let helpers = try Self.backtickedNames(after: "One folder holds helpers and no suite:", in: bullet)
        #expect(features.count > 10, "sanity: the feature list was found")
        #expect(Set(helpers) == Self.helperFolders, "the doc and this suite name different helper folders")
        #expect(Set(features).isDisjoint(with: helpers), "a folder is named both as a feature and as a helper folder")

        let documented = Set(features).union(helpers)
        let onDisk = try Self.folders()
        #expect(
            onDisk.subtracting(documented).isEmpty,
            "name these folders in docs/testing-conventions.md: \(onDisk.subtracting(documented).sorted())")
        #expect(
            documented.subtracting(onDisk).isEmpty,
            "docs/testing-conventions.md names folders that do not exist: \(documented.subtracting(onDisk).sorted())")
    }
}
