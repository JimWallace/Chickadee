// Tests/CoreTests/RunnerManifestTests.swift
//
// `RunnerManifest` is the runner contract that `Job.manifest` carries.  Its
// wire form must stay byte-identical to what the server sent before the type
// existed, for two reasons: an older runner decodes `Job.manifest` as a
// `TestProperties`, and the runner's test-setup cache key hashes these bytes.
// `legacySanitized` below is the body of `runnerSanitized()` before this type,
// kept here as the fixed point the new encoding must match.

import Foundation
import Testing

@testable import Core

@Suite struct RunnerManifestTests {

    /// A manifest with a value in every field the runner keeps and in the
    /// server-only fields that it must drop.
    private static let full = TestProperties(
        gradingMode: .browser,
        submissionMode: .notebook,
        githubSubmission: true,
        githubStatusChecks: true,
        githubStarterRepository: "org/starter",
        requiredFiles: ["main.py"],
        testSuites: [
            TestSuiteEntry(tier: .pub, script: "test_a.sh", points: 2, sectionID: "s1"),
            TestSuiteEntry(
                tier: .release, script: "releasetest_f_one.py", generatedBy: "f",
                hint: "h", timeLimitSeconds: 4, failureDetail: .actualOnly),
        ],
        timeLimitSeconds: 12,
        makefile: MakefileConfig(target: "all"),
        starterNotebook: "starter.ipynb",
        language: .python,
        languageDeclared: true,
        minimumRunnerVersion: "0.5.0",
        patternFamilies: [
            PatternFamily(
                id: "f", name: "F", kind: .boundaryEquality, functionName: "f",
                paramNames: ["x"],
                cases: [PatternCase(key: "one", label: "one", args: [.int(1)], expected: .int(2))])
        ],
        notebookChecks: [NotebookCheck(id: "c", kind: .figureCount, minFigures: 1)],
        sections: [
            TestSuiteSection(
                id: "s1", name: "Part 1",
                variables: [FamilyVariable(name: "limit", value: .int(5))],
                expressions: [PersonalizationExpression(name: "secret", expression: "solution(seed)")])
        ],
        globalVariables: [FamilyVariable(name: "g", value: .string("v"))],
        globalExpressions: [PersonalizationExpression(name: "x", expression: "seed % 7")],
        datasets: [DatasetSpec(file: "data.csv", sampleSize: 10)],
        graderOnlyFiles: ["holdout.csv"],
        disabledBuiltInAwardIDs: ["first-try"],
        builtInAchievementsSeeded: true)

    /// The body of `runnerSanitized()` before `RunnerManifest`, unchanged.
    private static func legacySanitized(_ p: TestProperties) -> TestProperties {
        TestProperties(
            schemaVersion: p.schemaVersion,
            gradingMode: p.gradingMode,
            submissionMode: p.submissionMode,
            requiredFiles: p.requiredFiles,
            testSuites: p.testSuites,
            timeLimitSeconds: p.timeLimitSeconds,
            makefile: p.makefile,
            starterNotebook: p.starterNotebook,
            language: p.language,
            languageDeclared: p.languageDeclared,
            patternFamilies: [],
            notebookChecks: [],
            sections: p.sections.map {
                TestSuiteSection(id: $0.id, name: $0.name, variables: $0.variables, expressions: [])
            },
            globalVariables: p.globalVariables,
            globalExpressions: [],
            achievements: [])
    }

    private static func bytes<T: Encodable>(_ value: T) throws -> Data {
        try ManifestCodec.stableEncoder.encode(value)
    }

    @Test(arguments: [full, TestProperties(language: nil), TestProperties(language: .cpp, languageDeclared: true)])
    func wireBytesMatchTheLegacySanitizedManifest(_ manifest: TestProperties) throws {
        #expect(try Self.bytes(manifest.runnerManifest()) == Self.bytes(Self.legacySanitized(manifest)))
        #expect(try Self.bytes(manifest.runnerSanitized()) == Self.bytes(Self.legacySanitized(manifest)))
    }

    /// An older runner decodes `Job.manifest` as a `TestProperties`.
    @Test func olderRunnerDecodesTheWireForm() throws {
        let data = try Self.bytes(Self.full.runnerManifest())
        let decoded = try ManifestCodec.decoder.decode(TestProperties.self, from: data)
        #expect(decoded == Self.legacySanitized(Self.full))
    }

    @Test func roundTrips() throws {
        let manifest = Self.full.runnerManifest()
        let decoded = try ManifestCodec.decoder.decode(
            RunnerManifest.self, from: try Self.bytes(manifest))
        #expect(decoded == manifest)
    }

    @Test func keepsTheRunnerFields() {
        let manifest = Self.full.runnerManifest()
        #expect(manifest.gradingMode == .browser)
        #expect(manifest.requiredFiles == ["main.py"])
        #expect(manifest.testSuites == Self.full.testSuites)
        #expect(manifest.timeLimitSeconds == 12)
        #expect(manifest.makefile == MakefileConfig(target: "all"))
        #expect(manifest.starterNotebook == "starter.ipynb")
        #expect(manifest.language == .python)
        #expect(manifest.languageDeclared == true)
        #expect(manifest.globalVariables == [FamilyVariable(name: "g", value: .string("v"))])
        #expect(manifest.sections.map(\.variables) == [[FamilyVariable(name: "limit", value: .int(5))]])
    }

    /// Expression source can hold reference-solution code.  It must not reach
    /// a runner by either route.
    @Test func dropsExpressionSource() throws {
        let manifest = Self.full.runnerManifest()
        #expect(manifest.sections.allSatisfy { $0.expressions.isEmpty })
        let json = try #require(String(data: try Self.bytes(manifest), encoding: .utf8))
        #expect(!json.contains("solution(seed)"))
        #expect(!json.contains("seed % 7"))
    }

    @Test func dropsServerOnlyFields() throws {
        let json = try #require(
            String(data: try Self.bytes(Self.full.runnerManifest()), encoding: .utf8))
        for key in [
            "githubSubmission", "githubStarterRepository", "minimumRunnerVersion", "testItems",
            "patternFamilies", "notebookChecks", "datasets", "graderOnlyFiles",
            "disabledBuiltInAwardIDs", "builtInAchievementsSeeded", "achievements", "activity",
        ] {
            #expect(!json.contains("\"\(key)\""), "runner manifest carries \(key)")
        }
    }

    /// `Job` built from a full manifest keeps only the runner contract, and
    /// its wire form decodes back to the same job manifest.
    @Test func jobCarriesTheRunnerManifest() throws {
        let url = try #require(URL(string: "https://example.test/x"))
        let job = Job(
            submissionID: "s", testSetupID: "t", attemptNumber: 1,
            submissionURL: url, testSetupURL: url, manifest: Self.full, language: .python)
        #expect(job.manifest == Self.full.runnerManifest())
        let decoded = try JSONDecoder().decode(Job.self, from: try JSONEncoder().encode(job))
        #expect(decoded.manifest == job.manifest)
    }
}
