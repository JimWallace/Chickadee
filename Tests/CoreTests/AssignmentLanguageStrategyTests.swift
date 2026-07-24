import Foundation
import Testing

@testable import Core

@Suite struct AssignmentLanguageStrategyTests {
    @Test func inputsFileName() {
        #expect(AssignmentLanguage.python.inputsFileName == "_ck_inputs.py")
        #expect(AssignmentLanguage.r.inputsFileName == "_ck_inputs.R")
    }

    @Test func literalDispatch() {
        #expect(AssignmentLanguage.python.literal(.bool(true)) == "True")
        #expect(AssignmentLanguage.r.literal(.bool(true)) == "TRUE")
        #expect(AssignmentLanguage.python.literal(.null) == "None")
        #expect(AssignmentLanguage.r.literal(.null) == "NULL")
        #expect(AssignmentLanguage.r.literal(.array([.string("a"), .string("b")])) == "c(\"a\", \"b\")")
    }

    @Test func pythonInputsFileIsByteForByteHistorical() {
        // Must match the historical _ck_inputs.py writer exactly (keys sorted,
        // "key": value, per line WITH trailing comma, closing brace, trailing \n).
        let body = AssignmentLanguage.python.renderInputsFile(["b": "2", "a": "'x'"])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + "_ck = {\n"
            + "    \"a\": 'x',\n"
            + "    \"b\": 2,\n"
            + "}\n"
        #expect(body == expected)
    }

    @Test func rInputsFileSingle() {
        let body = AssignmentLanguage.r.renderInputsFile(["reads": "c(\"AC\", \"GT\")"])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + ".ck_inputs <- list(\n"
            + "    `reads` = c(\"AC\", \"GT\")\n"
            + ")\n"
        #expect(body == expected)
    }

    @Test func rInputsFileMultipleHasNoTrailingComma() {
        let body = AssignmentLanguage.r.renderInputsFile(["a": "1", "b": "2"])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + ".ck_inputs <- list(\n"
            + "    `a` = 1,\n"
            + "    `b` = 2\n"
            + ")\n"
        #expect(body == expected)
    }

    @Test func rInputsFileEmpty() {
        let body = AssignmentLanguage.r.renderInputsFile([:])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + ".ck_inputs <- list()\n"
        #expect(body == expected)
    }

    // MARK: - Persisted manifest language

    /// The reason the field exists: a suite made up only of pattern families
    /// has no `.R` script to sniff, so without a recorded language it would
    /// resolve back to Python on every save.
    @Test func recordedLanguageWinsOverSniffingAnEmptySuite() {
        let sniffed = TestProperties(testSuites: [])
        #expect(AssignmentLanguage.resolve(manifest: sniffed) == .python)

        let recorded = TestProperties(testSuites: [], language: .r)
        #expect(AssignmentLanguage.resolve(manifest: recorded) == .r)
    }

    /// Nil means "written before the language was recorded" and must stay
    /// distinguishable from an explicit answer, so it emits no key at all.
    @Test func absentLanguageEmitsNoKeyAndRoundTrips() throws {
        let manifest = TestProperties(testSuites: [])
        let encoded = try JSONEncoder().encode(manifest)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("\"language\""))

        let decoded = try JSONDecoder().decode(TestProperties.self, from: encoded)
        #expect(decoded.language == nil)
    }

    /// Both languages round-trip and survive the runner-facing projection —
    /// Python is recorded explicitly, not left to be re-inferred.
    @Test(arguments: [AssignmentLanguage.python, .r])
    func recordedLanguageRoundTripsAndSurvivesRunnerSanitize(
        _ language: AssignmentLanguage
    ) throws {
        let manifest = TestProperties(testSuites: [], language: language)
        let encoded = try JSONEncoder().encode(manifest)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"language\":\"\(language.rawValue)\""))

        let decoded = try JSONDecoder().decode(TestProperties.self, from: encoded)
        #expect(decoded.language == language)
        #expect(decoded.runnerSanitized().language == language)
        #expect(AssignmentLanguage.resolve(manifest: decoded) == language)
    }

    /// An explicitly-recorded Python assignment must not be re-sniffed as R by
    /// a stray `.R` file in its suite — the recorded answer is authoritative.
    @Test func explicitPythonSurvivesAnRScriptInTheSuite() {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "publictest_a.R")],
            language: .python)
        #expect(AssignmentLanguage.resolve(manifest: manifest) == .python)
    }

    /// A legacy manifest with no `language` key must still decode.
    @Test func legacyManifestWithoutLanguageDecodes() throws {
        let legacy = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
        let decoded = try JSONDecoder().decode(
            TestProperties.self, from: try #require(legacy.data(using: .utf8)))
        #expect(decoded.language == nil)
        #expect(AssignmentLanguage.resolve(manifest: decoded) == .python)
    }
}
