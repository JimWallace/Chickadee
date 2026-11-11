// Tests/CoreTests/AssignmentTypeTests.swift
//
// The declared assignment type (docs/assignment-types.md): its stored raw
// values, and the one-time derivation the backfill and the row creators use
// when no type is named. Browser grading means a Lab, even with an activity;
// otherwise an activity means a Class activity; otherwise an Assignment.

import Foundation
import Testing

@testable import Core

@Suite struct AssignmentTypeTests {

    private static func manifest(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    private static let bestMetric = #""activity":{"kind":"bestMetric"}"#

    /// The stored raw values are the storage format: they must not change.
    @Test func theStoredRawValuesAreFixed() {
        #expect(AssignmentType.allCases.map(\.rawValue) == ["assignment", "lab", "classActivity"])
    }

    @Test func aWorkerGradedSetupWithNoActivityIsAnAssignment() throws {
        let props = try Self.manifest(#"{"schemaVersion":1,"gradingMode":"worker","testSuites":[]}"#)
        #expect(AssignmentType.derivedDeclaration(manifest: props) == .assignment)
    }

    @Test func aManifestWithNoGradingModeIsAnAssignment() throws {
        let props = try Self.manifest(#"{"schemaVersion":1,"testSuites":[]}"#)
        #expect(AssignmentType.derivedDeclaration(manifest: props) == .assignment)
    }

    @Test func aBrowserGradedSetupIsALab() throws {
        let props = try Self.manifest(#"{"schemaVersion":1,"gradingMode":"browser","testSuites":[]}"#)
        #expect(AssignmentType.derivedDeclaration(manifest: props) == .lab)
    }

    /// HLTH 230 Lab 4b: browser-graded with a best-metric activity stays a Lab.
    @Test func aBrowserGradedSetupWithAnActivityIsStillALab() throws {
        let props = try Self.manifest(
            #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"# + Self.bestMetric + "}")
        #expect(props.activity != nil)
        #expect(AssignmentType.derivedDeclaration(manifest: props) == .lab)
    }

    @Test func aWorkerGradedSetupWithAnActivityIsAClassActivity() throws {
        let props = try Self.manifest(
            #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"# + Self.bestMetric + "}")
        #expect(props.activity != nil)
        #expect(AssignmentType.derivedDeclaration(manifest: props) == .classActivity)
    }

    /// Upload-only pins worker grading, so a browser-spelled upload-only setup
    /// is not a Lab.
    @Test func anUploadOnlySetupIsNeverALab() throws {
        let props = try Self.manifest(
            #"{"schemaVersion":1,"gradingMode":"browser","submissionMode":"uploadOnly","testSuites":[]}"#)
        #expect(AssignmentType.derivedDeclaration(manifest: props) == .assignment)
    }
}
