// Tests/APITests/Guards/APITestsLayoutTests.swift
//
// The layout of this test target: each suite lives in a feature folder, and
// the top level holds only the helpers that every folder shares. A suite added
// at the top level would start the flat directory again, so it fails here.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct APITestsLayoutTests {

    private static let root = repositoryRoot.appendingPathComponent("Tests/APITests")

    @Test func theTopLevelHoldsSharedHelpersOnly() throws {
        let topLevel = try FileManager.default.contentsOfDirectory(atPath: Self.root.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(topLevel.count > 10, "sanity: the helpers were found")

        let suites = try topLevel.filter { name in
            let source = try String(
                contentsOf: Self.root.appendingPathComponent(name), encoding: .utf8)
            return source.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("@Test")
            }
        }
        #expect(suites.isEmpty, "move these into a feature folder: \(suites.sorted())")
    }
}
