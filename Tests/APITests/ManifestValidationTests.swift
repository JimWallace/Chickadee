// Tests/APITests/ManifestValidationTests.swift
//
// Unit tests for validateManifestDependencies — cycle detection,
// unknown references, and self-references in test suite dependency graphs.

import Fluent
import Testing
import Vapor

@testable import APIServer
@testable import Core

@Suite struct ManifestValidationTests {

    // MARK: - Helpers

    /// Builds a TestProperties from a list of (script, dependsOn) pairs.
    private func manifest(_ suites: [(String, [String])]) throws -> TestProperties {
        let entries = suites.map { script, deps -> [String: Any] in
            var d: [String: Any] = ["tier": "public", "script": script]
            if !deps.isEmpty { d["dependsOn"] = deps }
            return d
        }
        let dict: [String: Any] = ["schemaVersion": 1, "testSuites": entries]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(TestProperties.self, from: data)
    }

    // MARK: - Valid graphs

    @Test func noDependencies() throws {
        let m = try manifest([("a.sh", []), ("b.sh", []), ("c.sh", [])])
        #expect(throws: Never.self) { try validateManifestDependencies(m) }
    }

    @Test func linearChain() throws {
        let m = try manifest([
            ("build.sh", []),
            ("unit.sh", ["build.sh"]),
            ("integration.sh", ["unit.sh"]),
        ])
        #expect(throws: Never.self) { try validateManifestDependencies(m) }
    }

    @Test func diamondDependency() throws {
        let m = try manifest([
            ("a.sh", []),
            ("b.sh", ["a.sh"]),
            ("c.sh", ["a.sh"]),
            ("d.sh", ["b.sh", "c.sh"]),
        ])
        #expect(throws: Never.self) { try validateManifestDependencies(m) }
    }

    @Test func singleSuiteNoDeps() throws {
        let m = try manifest([("only.sh", [])])
        #expect(throws: Never.self) { try validateManifestDependencies(m) }
    }

    @Test func emptySuites() throws {
        let m = try manifest([])
        #expect(throws: Never.self) { try validateManifestDependencies(m) }
    }

    // MARK: - Self-references

    @Test func selfReferenceThrows() throws {
        let m = try manifest([("a.sh", ["a.sh"])])
        let abort = try #require(throws: Abort.self) { try validateManifestDependencies(m) }
        #expect(abort.status == .unprocessableEntity)
        #expect(abort.reason.contains("cannot depend on itself"))
    }

    // MARK: - Unknown references

    @Test func unknownDependencyThrows() throws {
        let m = try manifest([("a.sh", ["nonexistent.sh"])])
        let abort = try #require(throws: Abort.self) { try validateManifestDependencies(m) }
        #expect(abort.status == .unprocessableEntity)
        #expect(abort.reason.contains("nonexistent.sh"))
    }

    // MARK: - Cycles

    @Test func simpleCycleThrows() throws {
        let m = try manifest([
            ("a.sh", ["b.sh"]),
            ("b.sh", ["a.sh"]),
        ])
        let abort = try #require(throws: Abort.self) { try validateManifestDependencies(m) }
        #expect(abort.status == .unprocessableEntity)
        #expect(abort.reason.contains("cycle"))
    }

    @Test func threeNodeCycleThrows() throws {
        let m = try manifest([
            ("a.sh", ["c.sh"]),
            ("b.sh", ["a.sh"]),
            ("c.sh", ["b.sh"]),
        ])
        let abort = try #require(throws: Abort.self) { try validateManifestDependencies(m) }
        #expect(abort.reason.contains("cycle"))
    }

    @Test func cycleInSubgraphWithValidNode() throws {
        // d.sh is fine; a → b → c → a is a cycle
        let m = try manifest([
            ("d.sh", []),
            ("a.sh", ["c.sh"]),
            ("b.sh", ["a.sh"]),
            ("c.sh", ["b.sh"]),
        ])
        let abort = try #require(throws: Abort.self) { try validateManifestDependencies(m) }
        #expect(abort.reason.contains("cycle"))
    }

    @Test func multipleDepsOneUnknownThrows() throws {
        let m = try manifest([
            ("a.sh", []),
            ("b.sh", ["a.sh", "missing.sh"]),
        ])
        let abort = try #require(throws: Abort.self) { try validateManifestDependencies(m) }
        #expect(abort.reason.contains("missing.sh"))
    }
}
