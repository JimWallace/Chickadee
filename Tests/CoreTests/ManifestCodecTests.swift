// Tests/CoreTests/ManifestCodecTests.swift
//
// `ManifestCodec.stableEncoder` is the one encoder for a manifest that is
// stored or hashed: equal values must give equal bytes, and a decode →
// encode round trip must keep every field.  `TestSuiteEntry.encode` and
// `TestProperties.encode` write only what differs from the defaults, so a
// manifest's bytes do not depend on which writer produced them.

import Foundation
import Testing

@testable import Core

@Suite struct ManifestCodecTests {

    /// A manifest with every optional field set, so a dropped field shows.
    private var fullManifest: TestProperties {
        TestProperties(
            gradingMode: .browser,
            submissionMode: .notebook,
            githubSubmission: true,
            githubStatusChecks: true,
            requiredFiles: ["warmup.py"],
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.py"),
                TestSuiteEntry(
                    tier: .release, script: "b.py", name: "B", dependsOn: ["a.py"], points: 0,
                    sectionID: "s1", hint: "Read the docstring.", timeLimitSeconds: 5,
                    failureDetail: .verdictOnly),
            ],
            timeLimitSeconds: 20,
            makefile: MakefileConfig(target: "all"),
            starterNotebook: "assignment.ipynb",
            language: .r,
            languageDeclared: true,
            minimumRunnerVersion: "0.5.1",
            activity: ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible),
            sections: [
                TestSuiteSection(
                    id: "s1", name: "Part 1",
                    variables: [FamilyVariable(name: "n", value: .int(3))],
                    expressions: [PersonalizationExpression(name: "k", expression: "seed %% 7")])
            ],
            globalVariables: [FamilyVariable(name: "g", value: .string("x"))],
            globalExpressions: [PersonalizationExpression(name: "e", expression: "1")],
            datasets: [DatasetSpec(file: "data.csv", sampleSize: 10)],
            graderOnlyFiles: ["answers.R"],
            disabledBuiltInAwardIDs: ["first-try"],
            builtInAchievementsSeeded: true)
    }

    @Test func equalValuesGiveEqualBytes() throws {
        let manifest = fullManifest
        let first = try ManifestCodec.stableEncoder.encode(manifest)
        for _ in 0..<20 {
            #expect(try ManifestCodec.stableEncoder.encode(manifest) == first)
        }
    }

    @Test func aRoundTripKeepsEveryField() throws {
        let manifest = fullManifest
        let bytes = try ManifestCodec.stableEncoder.encode(manifest)
        let decoded = try ManifestCodec.decoder.decode(TestProperties.self, from: bytes)
        #expect(decoded == manifest)
        // And the second encoding is the first: the form is a fixed point.
        #expect(try ManifestCodec.stableEncoder.encode(decoded) == bytes)
    }

    @Test func anEntryWritesOnlyWhatDiffersFromTheDefaults() throws {
        let bare = TestSuiteEntry(tier: .pub, script: "a.sh", name: "", failureDetail: .full)
        #expect(try encode(bare) == #"{"script":"a.sh","tier":"public"}"#)

        // 0 points is not the default, so it is written: a missing key decodes
        // to 1 and a 0-point gate would start counting toward the score.
        let gate = TestSuiteEntry(tier: .pub, script: "gate.sh", points: 0, timeLimitSeconds: 0)
        #expect(try encode(gate) == #"{"points":0,"script":"gate.sh","tier":"public"}"#)

        let full = TestSuiteEntry(
            tier: .secret, script: "s.py", name: "S", dependsOn: ["a.sh"], points: 3,
            generatedBy: "fam", sectionID: "s1", hint: "h", timeLimitSeconds: 7,
            failureDetail: .actualOnly)
        let decoded = try ManifestCodec.decoder.decode(TestSuiteEntry.self, from: Data(try encode(full).utf8))
        #expect(decoded == full)
    }

    @Test func emptyListsAndFalseFlagsAreOmitted() throws {
        let bytes = try encode(TestProperties())
        #expect(
            bytes
                == #"{"gradingMode":"worker","requiredFiles":[],"schemaVersion":1,"#
                + #""submissionMode":"notebook","testSuites":[],"timeLimitSeconds":10}"#)
    }

    private func encode(_ value: some Encodable) throws -> String {
        try #require(String(bytes: try ManifestCodec.stableEncoder.encode(value), encoding: .utf8))
    }
}
