// Tests/APITests/ManifestValidationTests.swift
//
// Unit tests for validateManifestDependencies — cycle detection,
// unknown references, and self-references in test suite dependency graphs.

import XCTest
import Vapor
@testable import chickadee_server
@testable import Core

final class ManifestValidationTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a TestProperties from a list of (script, dependsOn) pairs.
    private func manifest(_ suites: [(String, [String])]) throws -> TestProperties {
        let entries = suites.map { script, deps -> [String: Any] in
            var d: [String: Any] = ["tier": "public", "script": script]
            if !deps.isEmpty { d["dependsOn"] = deps }
            return d
        }
        let dict: [String: Any] = [
            "schemaVersion": 1,
            "testSuites": entries,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(TestProperties.self, from: data)
    }

    // MARK: - Valid graphs

    func testNoDependencies() throws {
        let m = try manifest([("a.sh", []), ("b.sh", []), ("c.sh", [])])
        XCTAssertNoThrow(try validateManifestDependencies(m))
    }

    func testLinearChain() throws {
        let m = try manifest([
            ("build.sh", []),
            ("unit.sh", ["build.sh"]),
            ("integration.sh", ["unit.sh"]),
        ])
        XCTAssertNoThrow(try validateManifestDependencies(m))
    }

    func testDiamondDependency() throws {
        let m = try manifest([
            ("a.sh", []),
            ("b.sh", ["a.sh"]),
            ("c.sh", ["a.sh"]),
            ("d.sh", ["b.sh", "c.sh"]),
        ])
        XCTAssertNoThrow(try validateManifestDependencies(m))
    }

    func testSingleSuiteNoDeps() throws {
        let m = try manifest([("only.sh", [])])
        XCTAssertNoThrow(try validateManifestDependencies(m))
    }

    func testEmptySuites() throws {
        let m = try manifest([])
        XCTAssertNoThrow(try validateManifestDependencies(m))
    }

    // MARK: - Self-references

    func testSelfReferenceThrows() throws {
        let m = try manifest([("a.sh", ["a.sh"])])
        XCTAssertThrowsError(try validateManifestDependencies(m)) { error in
            let abort = error as? Abort
            XCTAssertEqual(abort?.status, .unprocessableEntity)
            XCTAssertTrue(abort?.reason.contains("cannot depend on itself") ?? false,
                "Expected self-reference error, got: \(abort?.reason ?? "")")
        }
    }

    // MARK: - Unknown references

    func testUnknownDependencyThrows() throws {
        let m = try manifest([("a.sh", ["nonexistent.sh"])])
        XCTAssertThrowsError(try validateManifestDependencies(m)) { error in
            let abort = error as? Abort
            XCTAssertEqual(abort?.status, .unprocessableEntity)
            XCTAssertTrue(abort?.reason.contains("nonexistent.sh") ?? false,
                "Expected unknown dep error, got: \(abort?.reason ?? "")")
        }
    }

    // MARK: - Cycles

    func testSimpleCycleThrows() throws {
        let m = try manifest([
            ("a.sh", ["b.sh"]),
            ("b.sh", ["a.sh"]),
        ])
        XCTAssertThrowsError(try validateManifestDependencies(m)) { error in
            let abort = error as? Abort
            XCTAssertEqual(abort?.status, .unprocessableEntity)
            XCTAssertTrue(abort?.reason.contains("cycle") ?? false,
                "Expected cycle error, got: \(abort?.reason ?? "")")
        }
    }

    func testThreeNodeCycleThrows() throws {
        let m = try manifest([
            ("a.sh", ["c.sh"]),
            ("b.sh", ["a.sh"]),
            ("c.sh", ["b.sh"]),
        ])
        XCTAssertThrowsError(try validateManifestDependencies(m)) { error in
            let abort = error as? Abort
            XCTAssertTrue(abort?.reason.contains("cycle") ?? false)
        }
    }

    func testCycleInSubgraphWithValidNode() throws {
        // d is fine; a → b → c → a is a cycle
        let m = try manifest([
            ("d.sh", []),
            ("a.sh", ["c.sh"]),
            ("b.sh", ["a.sh"]),
            ("c.sh", ["b.sh"]),
        ])
        XCTAssertThrowsError(try validateManifestDependencies(m)) { error in
            let abort = error as? Abort
            XCTAssertTrue(abort?.reason.contains("cycle") ?? false)
        }
    }

    func testMultipleDepsOneUnknownThrows() throws {
        let m = try manifest([
            ("a.sh", []),
            ("b.sh", ["a.sh", "missing.sh"]),
        ])
        XCTAssertThrowsError(try validateManifestDependencies(m)) { error in
            let abort = error as? Abort
            XCTAssertTrue(abort?.reason.contains("missing.sh") ?? false)
        }
    }
}
