// Core/RunnerManifest.swift
//
// The part of the manifest that a runner receives on `Job.manifest`.  Before
// this type, the job carried a whole `TestProperties` with the server-only
// fields emptied by `runnerSanitized()`.  The worker could still read those
// fields, and found them empty without an error.  This type holds only the
// runner contract, so a worker read of a server-only field does not compile,
// and a new `TestProperties` field reaches a runner only when a person adds it
// here.  See docs/manifest-format-v2.md, D1.
//
// The wire form is unchanged: this type encodes and decodes through the
// `TestProperties` codec.  An older runner, which decodes `Job.manifest` as a
// `TestProperties`, reads it without a change, and the runner's test-setup
// cache key (`testSetupCacheKey`), which hashes these bytes, stays the same.
//
// What it leaves out, and why:
// - Pattern families and notebook checks.  By the time the zip reaches a
//   runner, each generated test is an ordinary script.  An unknown
//   `PatternKind` or `NotebookCheckKind` value would also fail the decode of
//   the whole manifest on an older runner.
// - Global and section `=` expressions.  Their source can hold
//   reference-solution code.  Resolved values travel on
//   `Job.personalizedInputs`.
// - `datasets` and `graderOnlyFiles`.  The runner receives the materialized
//   file on the job, and the grader-only file in the test-setup zip.
// - `activity`.  A match's needs travel on the job, and an `ActivityKind` that
//   an older runner predates would fail its decode.
// - Achievements, awards, GitHub settings and `minimumRunnerVersion`.  These
//   are server-side.

/// The manifest fields that a runner reads to grade a submission.
public struct RunnerManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var gradingMode: GradingMode
    public var submissionMode: SubmissionMode
    /// The files the student must supply.
    public var requiredFiles: [String]
    /// The test scripts, in run order.
    public var testSuites: [TestSuiteEntry]
    /// The assignment-wide per-test time limit, in seconds.
    public var timeLimitSeconds: Int
    public var makefile: MakefileConfig?
    public var starterNotebook: String?
    public var language: AssignmentLanguage?
    /// See `TestProperties.languageDeclared`.  A runner needs it to tell
    /// "declared to have no language" from "nobody has declared one".
    public var languageDeclared: Bool?
    /// The suite sections, with literal variables only.  The initializer
    /// removes every `=` expression: expression source can hold
    /// reference-solution code, and only resolved values reach grading.
    public var sections: [TestSuiteSection]
    /// Assignment-scope literal variables.
    public var globalVariables: [FamilyVariable]

    /// Copies the runner contract out of a full manifest.
    public init(_ manifest: TestProperties) {
        schemaVersion = manifest.schemaVersion
        gradingMode = manifest.gradingMode
        submissionMode = manifest.submissionMode
        requiredFiles = manifest.requiredFiles
        testSuites = manifest.testSuites
        timeLimitSeconds = manifest.timeLimitSeconds
        makefile = manifest.makefile
        starterNotebook = manifest.starterNotebook
        language = manifest.language
        languageDeclared = manifest.languageDeclared
        sections = manifest.sections.map { section in
            TestSuiteSection(
                id: section.id, name: section.name,
                variables: section.variables, expressions: [])
        }
        globalVariables = manifest.globalVariables
    }

    /// The same fields as a `TestProperties`, with every other field at its
    /// default.  This is the value that goes on the wire.  Internal on
    /// purpose: outside Core, a read through it would find each server-only
    /// field empty, which is the silent read this type exists to prevent.
    var testProperties: TestProperties {
        TestProperties(
            schemaVersion: schemaVersion,
            gradingMode: gradingMode,
            submissionMode: submissionMode,
            requiredFiles: requiredFiles,
            testSuites: testSuites,
            timeLimitSeconds: timeLimitSeconds,
            makefile: makefile,
            starterNotebook: starterNotebook,
            language: language,
            languageDeclared: languageDeclared,
            sections: sections,
            globalVariables: globalVariables)
    }

    public init(from decoder: any Decoder) throws {
        self.init(try TestProperties(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try testProperties.encode(to: encoder)
    }
}

extension TestProperties {
    /// The runner contract of this manifest.  `Job.manifest` carries it.
    public func runnerManifest() -> RunnerManifest {
        RunnerManifest(self)
    }
}
