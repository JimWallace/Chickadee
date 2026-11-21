// Tests/CoreTests/Runner/JobCodableTests.swift
//
// The `Job` wire form, the pattern-case fields it carries, and the
// runner-sanitized manifest it sends.
// Split by subject out of the former `CoreCodableTests`.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import Core

@Suite struct JobCodableTests: ISO8601CodingSuite {

    @Test func jobRoundTrip() throws {
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(
                """
                { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 5 }
                """.utf8))

        let job = Job(
            submissionID: "sub_job",
            testSetupID: "setup_job",
            attemptNumber: 1,
            submissionURL: testURL("http://localhost:8080/worker/artifacts/sub_job"),
            testSetupURL: testURL("http://localhost:8080/api/v1/testsetups/setup_job/download"),
            manifest: manifest,
            submissionFilename: "warmup.py", language: nil
        )

        let data = try encoder.encode(job)
        let decoded = try decoder.decode(Job.self, from: data)
        #expect(decoded.submissionID == "sub_job")
        #expect(decoded.testSetupID == "setup_job")
        #expect(decoded.attemptNumber == 1)
        #expect(decoded.submissionFilename == "warmup.py")
        #expect(decoded.manifest.timeLimitSeconds == 5)
    }

    @Test func jobSubmissionFilenameNilRoundTrip() throws {
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(
                """
                { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 10 }
                """.utf8))

        let job = Job(
            submissionID: "sub_zip",
            testSetupID: "setup_zip",
            attemptNumber: 3,
            submissionURL: testURL("http://localhost/a"),
            testSetupURL: testURL("http://localhost/b"),
            manifest: manifest,
            submissionFilename: nil, language: nil
        )
        let data = try encoder.encode(job)
        let decoded = try decoder.decode(Job.self, from: data)
        #expect(decoded.submissionFilename == nil)
    }

    @Test func jobPersonalizedInputsRoundTrip() throws {
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(#"{ "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 5 }"#.utf8))
        let job = Job(
            submissionID: "s", testSetupID: "t", attemptNumber: 1,
            submissionURL: testURL("http://localhost/a"),
            testSetupURL: testURL("http://localhost/b"),
            manifest: manifest,
            assignmentSeed: "deadbeef",
            personalizedInputs: ["patients": "[{'mrn': '1'}]", "adults_expected": "2"], language: nil)
        let decoded = try decoder.decode(Job.self, from: encoder.encode(job))
        #expect(decoded.personalizedInputs?["patients"] == "[{'mrn': '1'}]")
        #expect(decoded.personalizedInputs?["adults_expected"] == "2")
        #expect(decoded.assignmentSeed == "deadbeef")
    }

    @Test func jobWithoutPersonalizedInputsDecodesNil() throws {
        // Back-compat: a payload from an older server omits the new fields.
        let json = #"""
            { "submissionID": "s", "testSetupID": "t", "attemptNumber": 1,
              "submissionURL": "http://localhost/a", "testSetupURL": "http://localhost/b",
              "manifest": { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 5 } }
            """#
        let decoded = try decoder.decode(Job.self, from: Data(json.utf8))
        #expect(decoded.personalizedInputs == nil)
        #expect(decoded.assignmentSeed == nil)
    }

    @Test func patternCaseExpectedVarRefRoundTrip() throws {
        let c = PatternCase(
            key: "01", label: "Adults", args: [.null], expected: .null,
            argVarRefs: ["patients"], expectedVarRef: "adults_expected")
        let decoded = try decoder.decode(PatternCase.self, from: encoder.encode(c))
        #expect(decoded.expectedVarRef == "adults_expected")
        #expect(decoded.argVarRefs == ["patients"])
    }

    @Test func patternCaseWithoutExpectedVarRefDecodesNil() throws {
        let json = #"{ "key": "01", "label": "L", "args": [1], "expected": 2 }"#
        let decoded = try decoder.decode(PatternCase.self, from: Data(json.utf8))
        #expect(decoded.expectedVarRef == nil)
    }

    @Test func runnerSanitizedStripsPatternFamilies() throws {
        let family = PatternFamily(
            id: "bmi",
            name: "BMI boundaries",
            kind: .boundaryEquality,
            functionName: "classify_bmi"
        )
        let manifest = TestProperties(
            schemaVersion: 1,
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.py")],
            timeLimitSeconds: 7,
            language: nil,
            patternFamilies: [family]
        )

        let sanitized = manifest.runnerSanitized()
        #expect(sanitized.patternFamilies.isEmpty)
        #expect(sanitized.testSuites == manifest.testSuites)
        #expect(sanitized.timeLimitSeconds == 7)

        let roundTripped = try decoder.decode(
            TestProperties.self,
            from: try encoder.encode(sanitized)
        )
        #expect(roundTripped.patternFamilies.isEmpty)
    }

    @Test func runnerSanitizedStripsNotebookChecks() throws {
        let check = NotebookCheck(
            id: "df_shape",
            kind: .dataFrameShape,
            tier: .pub,
            points: 1,
            variable: "df",
            expectedRows: 250,
            expectedCols: 13
        )
        let manifest = TestProperties(
            schemaVersion: 1,
            testSuites: [
                TestSuiteEntry(
                    tier: .pub,
                    script: "publiccheck_df_shape.py",
                    generatedByCheck: "df_shape"
                )
            ],
            timeLimitSeconds: 7,
            language: nil,
            notebookChecks: [check]
        )

        let sanitized = manifest.runnerSanitized()
        #expect(sanitized.notebookChecks.isEmpty)
        // testSuites entries — including the one with generatedByCheck —
        // are preserved.  Only the spec list is stripped.
        #expect(sanitized.testSuites.count == 1)
        #expect(sanitized.testSuites.first?.generatedByCheck == "df_shape")
    }
}
