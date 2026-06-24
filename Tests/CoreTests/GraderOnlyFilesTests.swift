// Tests/CoreTests/GraderOnlyFilesTests.swift
//
// Pins the grader-only-files manifest marker (option B foundation — see
// docs/datasets.md): Codable back-compat (a manifest without the key decodes
// to empty), the round-trip, the runnerSanitized() strip (the runner gets the
// file via the zip, never the marker), and the set helper used to union into
// the student-facing reservedNames filters.

import Foundation
import Testing

@testable import Core

@Suite struct GraderOnlyFilesTests {

    @Test func manifestWithoutGraderOnlyKeyDecodesEmpty() throws {
        let json = #"{"schemaVersion":1}"#
        let decoded = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        #expect(decoded.graderOnlyFiles.isEmpty)
        #expect(decoded.graderOnlyFileSet.isEmpty)
    }

    @Test func graderOnlyFilesRoundTrip() throws {
        let manifest = TestProperties(graderOnlyFiles: ["test.csv", "answers.json"])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.graderOnlyFiles == ["test.csv", "answers.json"])
        #expect(decoded.graderOnlyFileSet == Set(["test.csv", "answers.json"]))
    }

    @Test func runnerSanitizedStripsGraderOnlyFiles() {
        let manifest = TestProperties(graderOnlyFiles: ["test.csv"])
        #expect(manifest.runnerSanitized().graderOnlyFiles.isEmpty)
    }

    @Test func emptyByDefault() {
        #expect(TestProperties().graderOnlyFiles.isEmpty)
    }
}
