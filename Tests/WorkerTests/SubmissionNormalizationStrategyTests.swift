// Tests/WorkerTests/SubmissionNormalizationStrategyTests.swift
//
// Which normalization a submission gets, asserted per language.
//
// This is the one language decision the compiler cannot force: the routing is a
// STRATEGY, and its Python arm is reached by falling through content and
// extension probes rather than by naming Python. So a new language does not
// fail to compile here — it silently gets Python's normalizer, which for a
// notebook submission means the `.ipynb` is turned into a Python module and the
// suite grades nothing it recognises.
//
// The table below is the whole contract, and it is parameterised over
// `allCases` wherever it can be, so a fourth language has to appear in it.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct SubmissionNormalizationStrategyTests {

    static func manifest(
        suiteScripts: [String], requiredFiles: [String] = [],
        language: AssignmentLanguage? = nil
    ) -> TestProperties {
        TestProperties(
            requiredFiles: requiredFiles,
            testSuites: suiteScripts.map { TestSuiteEntry(tier: .pub, script: $0) },
            timeLimitSeconds: 10,
            language: language
        )
    }

    static func emptyDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-normstrategy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A suite in `language` plus a notebook submission — the ordinary student
    /// workflow — must NOT be handed to the Python normalizer unless the
    /// assignment is actually Python.
    @Test(arguments: AssignmentLanguage.allCases)
    func aNotebookSubmissionIsNormalizedForItsOwnLanguage(_ language: AssignmentLanguage) throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = "publictest_a.\(language.generatedScriptExtension)"
        let result = submissionNormalization(
            manifest: Self.manifest(
                suiteScripts: [script], language: language == .cpp ? .cpp : nil),
            submissionFilename: "lab.ipynb",
            submissionDirectory: dir)

        switch language {
        case .python:
            #expect(result == .pythonModule)
        case .r, .lua, .octave, .cpp:
            #expect(
                result == .extractToSource(forcedLanguage: language),
                """
                A \(language) assignment with a notebook submission got \(result). Falling through \
                to the Python normalizer turns the `.ipynb` into a Python module, so the \
                \(language) suite finds nothing it can grade — and the submission's own kernelspec \
                cannot be trusted to correct it, because the in-browser editor can rewrite it.
                """)
        }
    }

    /// The same, for a plain source-file upload rather than a notebook.
    @Test(arguments: AssignmentLanguage.allCases)
    func aSourceSubmissionIsNormalizedForItsOwnLanguage(_ language: AssignmentLanguage) throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ext = language.generatedScriptExtension
        // C++'s generated scripts are `.sh` (no signal, by design) — its
        // manifest records the language and its submissions are `.cpp`.
        let submissionExt = language == .cpp ? "cpp" : ext
        let result = submissionNormalization(
            manifest: Self.manifest(
                suiteScripts: ["publictest_a.\(ext)"],
                language: language == .cpp ? .cpp : nil),
            submissionFilename: "solution.\(submissionExt)",
            submissionDirectory: dir)

        switch language {
        case .python: #expect(result == .pythonModule)
        case .r, .lua, .octave, .cpp:
            #expect(result == .extractToSource(forcedLanguage: language))
        }
    }

    // MARK: - Behaviour that must NOT change

    /// A required `.py` file wins over everything — the first check in the
    /// original routing, preserved.
    @Test func aRequiredPythonFileForcesThePythonNormalizer() throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = submissionNormalization(
            manifest: Self.manifest(suiteScripts: ["publictest_a.R"], requiredFiles: ["warmup.py"]),
            submissionFilename: "lab.ipynb",
            submissionDirectory: dir)
        #expect(result == .pythonModule)
    }

    /// A MIXED suite stays on the Python normalizer. This is the case that
    /// makes the routing more than "resolve the language and dispatch":
    /// `AssignmentLanguage.resolve` answers `.r` for any suite containing an
    /// `.R` script, while this routing deliberately keeps Python's normalizer
    /// whenever Python is present at all. Changing that would alter how every
    /// existing mixed assignment prepares submissions.
    @Test func aMixedPythonAndRSuiteKeepsThePythonNormalizer() throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = submissionNormalization(
            manifest: Self.manifest(suiteScripts: ["publictest_a.py", "publictest_b.R"]),
            submissionFilename: "lab.ipynb",
            submissionDirectory: dir)
        #expect(result == .pythonModule)
    }

    /// An assignment with no language signal at all falls back to Python, which
    /// is what every pre-existing assignment without a recorded language does.
    @Test func anUnsignalledManifestFallsBackToPython() throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = submissionNormalization(
            manifest: Self.manifest(suiteScripts: ["publictest_a.sh"]),
            submissionFilename: "lab.ipynb",
            submissionDirectory: dir)
        #expect(result == .pythonModule)
    }

    /// A shell-only suite with a submission that looks like nothing in
    /// particular gets the generic path, unforced.
    @Test func anUnrecognisedSubmissionGetsGenericExtraction() throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = submissionNormalization(
            manifest: Self.manifest(suiteScripts: ["publictest_a.sh"]),
            submissionFilename: "notes.txt",
            submissionDirectory: dir)
        #expect(result == .extractToSource(forcedLanguage: nil))
    }

    /// The legacy boolean is still the same answer, so the call site's old
    /// behaviour is pinned while the strategy is what everything reads.
    @Test(arguments: AssignmentLanguage.allCases)
    func theLegacyBooleanAgreesWithTheStrategy(_ language: AssignmentLanguage) throws {
        let dir = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = Self.manifest(
            suiteScripts: ["publictest_a.\(language.generatedScriptExtension)"])
        let strategy = submissionNormalization(
            manifest: manifest, submissionFilename: "lab.ipynb", submissionDirectory: dir)
        let legacy = shouldNormalizePythonSubmission(
            manifest: manifest, submissionFilename: "lab.ipynb", submissionDirectory: dir)
        #expect((strategy == .pythonModule) == legacy)
    }
}
