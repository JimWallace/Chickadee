// Tests/CoreTests/ManifestV2Tests.swift
//
// The `schemaVersion: 2` manifest form (docs/manifest-format-v2.md, phase 3).
// Phase 3 reads v2 and still writes v1.  These tests pin:
// - an exact round trip through the v2 form for every manifest that
//   `v2Envelope()` accepts, through bytes and back;
// - that `v2Envelope()` refuses each manifest the v2 form cannot hold;
// - the v2 key shapes that phase 4 will write;
// - that a value read from v2 equals the same value built in code, and the
//   v1 writer writes it back as valid v1;
// - that a hand-written v2 document decodes.

import Foundation
import Testing

@testable import Core

@Suite struct ManifestV2Tests {

    /// A manifest with a value in every field.
    static let full = TestProperties(
        gradingMode: .browser,
        submissionMode: .uploadOnly,
        githubSubmission: true,
        githubStatusChecks: true,
        githubStarterRepository: "org/starter",
        requiredFiles: ["warmup.py", "main.py"],
        testSuites: [
            TestSuiteEntry(
                tier: .release, script: "releasetest_fam_01.py", name: "Test A",
                dependsOn: ["test_b.sh"], points: 3, generatedBy: "fam",
                sectionID: "sec1", hint: "look closer", timeLimitSeconds: 20,
                failureDetail: .actualOnly),
            TestSuiteEntry(tier: .pub, script: "pubtest_chk.py", points: 0, generatedByCheck: "chk"),
            TestSuiteEntry(tier: .secret, script: "test_b.sh"),
        ],
        timeLimitSeconds: 30,
        makefile: MakefileConfig(target: "all"),
        starterNotebook: "assignment.ipynb",
        language: .r,
        languageDeclared: true,
        minimumRunnerVersion: "0.5.0",
        activity: ClassActivity(
            kind: .beatTheInstructor, leaderboardVisibility: .visible, opponentFile: "bot.py",
            window: LiveSessionWindow(
                opensAtISO: "2026-01-05T14:00:00Z", closesAtISO: "2026-01-05T16:00:00Z")),
        patternFamilies: [
            PatternFamily(
                id: "fam", name: "Family", kind: .boundaryEquality,
                functionName: "f", paramNames: ["x"],
                defaults: PatternDefaults(tier: .pub, points: 2, hint: "h"),
                cases: [PatternCase(key: "01", label: "one", args: [.int(1)], expected: .string("ok"))],
                variables: [FamilyVariable(name: "v", value: .int(1))])
        ],
        notebookChecks: [
            NotebookCheck(id: "chk", kind: .dataFrameShape, variable: "df", expectedRows: 1, expectedCols: 2)
        ],
        sections: [
            TestSuiteSection(
                id: "sec1", name: "Section 1",
                variables: [FamilyVariable(name: "sv", value: .null)],
                expressions: [PersonalizationExpression(name: "se", expression: "seed + 1")]),
            TestSuiteSection(id: "sec2", name: "Section 2"),
        ],
        globalVariables: [
            FamilyVariable(name: "gv", value: .int(3)),
            FamilyVariable(name: "gnull", value: .null),
        ],
        globalExpressions: [PersonalizationExpression(name: "ge", expression: "seed * 2")],
        datasets: [DatasetSpec(file: "pool.csv", kind: .rowSample, sampleSize: 5)],
        graderOnlyFiles: ["holdout.csv"],
        achievements: [
            Achievement(
                id: "ach", name: "Ach", scope: .individual,
                conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)],
                reward: AchievementReward(type: .badge, label: "B"))
        ],
        disabledBuiltInAwardIDs: ["first-try-perfect"],
        builtInAchievementsSeeded: true)

    static let roundTripCases: [TestProperties] = [
        full,
        TestProperties(language: nil),
        TestProperties(language: nil, languageDeclared: true),
        TestProperties(language: .cpp, languageDeclared: true),
        TestProperties(language: .python, languageDeclared: true, builtInAchievementsSeeded: true),
        TestProperties(
            starterNotebook: "a.ipynb", language: nil, languageDeclared: true,
            datasets: [DatasetSpec(file: "a.ipynb")]),
    ]

    private static func v2Bytes(_ p: TestProperties) throws -> Data {
        let envelope = try #require(p.v2Envelope())
        return try ManifestCodec.stableEncoder.encode(envelope)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Round trip

    @Test(arguments: roundTripCases)
    func v2RoundTripsExactly(_ manifest: TestProperties) throws {
        let data = try Self.v2Bytes(manifest)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(TestProperties.wireVersion(of: text) == 2)
        let decoded = try ManifestCodec.decoder.decode(TestProperties.self, from: data)
        // In memory, a value read from v2 equals the same value built in code.
        #expect(decoded == manifest)
    }

    /// A manifest read from v2 and written by the v1 writer is valid v1 with
    /// the same content, and its bytes equal the v1 bytes of the original.
    @Test(arguments: roundTripCases)
    func v2ReadThenV1WriteMatchesV1(_ manifest: TestProperties) throws {
        let decoded = try ManifestCodec.decoder.decode(TestProperties.self, from: Self.v2Bytes(manifest))
        let v1 = try ManifestCodec.stableEncoder.encode(decoded)
        #expect(v1 == (try ManifestCodec.stableEncoder.encode(manifest)))
        #expect(try Self.object(v1)["schemaVersion"] as? Int == TestProperties.v1SchemaVersion)
    }

    /// The runner manifest of a v2-read manifest is still v1 on the wire.
    @Test func runnerManifestOfAV2ReadIsV1() throws {
        let decoded = try ManifestCodec.decoder.decode(TestProperties.self, from: Self.v2Bytes(Self.full))
        let wire = try Self.object(try ManifestCodec.stableEncoder.encode(decoded.runnerManifest()))
        #expect(wire["schemaVersion"] as? Int == 1)
        #expect(
            try ManifestCodec.stableEncoder.encode(decoded.runnerManifest())
                == ManifestCodec.stableEncoder.encode(Self.full.runnerManifest()))
    }

    // MARK: - Refusals

    @Test func refusesAnEntryWithBothGeneratorFields() {
        let both = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "x.py", generatedBy: "f", generatedByCheck: "c")],
            language: nil, languageDeclared: true)
        #expect(both.v2Envelope() == nil)
    }

    @Test func refusesALanguageWithoutItsFlag() {
        #expect(TestProperties(language: .python).v2Envelope() == nil)
    }

    @Test func refusesADuplicateFileInOneList() {
        let duplicate = TestProperties(requiredFiles: ["a.py", "a.py"], language: nil, languageDeclared: true)
        #expect(duplicate.v2Envelope() == nil)
    }

    @Test func refusesListsWhoseOrderTheFileListCannotHold() {
        let crossed = TestProperties(
            requiredFiles: ["a", "b"], language: nil, languageDeclared: true, graderOnlyFiles: ["b", "a"])
        #expect(crossed.v2Envelope() == nil)
    }

    @Test func refusesAwardsWithoutTheSeededFlag() {
        let unseeded = TestProperties(
            language: nil, languageDeclared: true, disabledBuiltInAwardIDs: ["first-try-perfect"])
        #expect(unseeded.v2Envelope() == nil)
    }

    // MARK: - Shape

    @Test func v2KeysHaveTheNewShape() throws {
        let object = try Self.object(Self.v2Bytes(Self.full))
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["language"] as? String == "r")
        for v1Key in [
            "languageDeclared", "githubSubmission", "githubStatusChecks", "githubStarterRepository",
            "requiredFiles", "graderOnlyFiles", "datasets", "starterNotebook", "globalVariables",
            "globalExpressions", "achievements", "disabledBuiltInAwardIDs", "builtInAchievementsSeeded",
            "patternFamilies", "notebookChecks",
        ] {
            #expect(object[v1Key] == nil, "v2 still writes \(v1Key)")
        }
        let github = try #require(object["github"] as? [String: Any])
        #expect(github["submission"] as? Bool == true)
        #expect(github["starterRepository"] as? String == "org/starter")
        let files = try #require(object["files"] as? [[String: Any]])
        #expect(
            files.map { $0["name"] as? String } == [
                "warmup.py", "main.py", "holdout.csv", "pool.csv", "assignment.ipynb",
            ])
        let suites = try #require(object["testSuites"] as? [[String: Any]])
        #expect((suites[0]["origin"] as? [String: String]) == ["family": "fam"])
        #expect((suites[1]["origin"] as? [String: String]) == ["check": "chk"])
        #expect(suites[2]["origin"] == nil)
        #expect(suites.allSatisfy { $0["generatedBy"] == nil && $0["generatedByCheck"] == nil })
        let inputs = try #require(object["inputs"] as? [[String: Any]])
        #expect(inputs.map { $0["name"] as? String } == ["gv", "gnull", "ge"])
        #expect(inputs[1].keys.contains("value"))
        #expect(inputs[2]["expression"] as? String == "seed * 2")
    }

    @Test func noLanguageIsWrittenAsNone() throws {
        let none = TestProperties(language: nil, languageDeclared: true)
        #expect(try Self.object(Self.v2Bytes(none))["language"] as? String == "none")
        let undeclared = TestProperties(language: nil)
        #expect(try Self.object(Self.v2Bytes(undeclared))["language"] == nil)
    }

    // MARK: - Hand-written v2

    @Test func decodesAHandWrittenV2Document() throws {
        let json = #"""
            {"schemaVersion": 2, "gradingMode": "worker", "language": "none",
             "files": [{"name": "main.py", "required": true}],
             "testSuites": [{"tier": "public", "script": "test_a.sh"},
                            {"tier": "public", "script": "pubtest_f_1.py", "origin": {"family": "f"}}],
             "inputs": [{"name": "limit", "value": 5}, {"name": "n", "expression": "seed % 3"}],
             "sections": [{"id": "s", "name": "S"}],
             "awards": {}}
            """#
        let p = try ManifestCodec.decoder.decode(TestProperties.self, from: Data(json.utf8))
        #expect(p.schemaVersion == 1)
        #expect(p.languageDeclaration == .noLanguage)
        #expect(p.requiredFiles == ["main.py"])
        #expect(p.testSuites.map(\.origin) == [.handWritten, .family(id: "f")])
        #expect(p.globalVariables == [FamilyVariable(name: "limit", value: .int(5))])
        #expect(p.globalExpressions == [PersonalizationExpression(name: "n", expression: "seed % 3")])
        #expect(p.sections == [TestSuiteSection(id: "s", name: "S")])
        #expect(p.builtInAchievementsSeeded)
        #expect(p.timeLimitSeconds == 10)
        #expect(p.submissionMode == .notebook)
    }

    @Test func refusesAnUnknownV2Language() {
        let json = #"{"schemaVersion": 2, "language": "cobol"}"#
        #expect(throws: DecodingError.self) {
            try ManifestCodec.decoder.decode(TestProperties.self, from: Data(json.utf8))
        }
    }

    /// Every version other than 2 is read as v1, as before phase 3.
    @Test func versionOneIsReadAsBefore() throws {
        let json = #"{"schemaVersion": 1, "requiredFiles": ["a.py"], "languageDeclared": true}"#
        let p = try ManifestCodec.decoder.decode(TestProperties.self, from: Data(json.utf8))
        #expect(p.schemaVersion == 1)
        #expect(p.requiredFiles == ["a.py"])
        #expect(p.languageDeclaration == .noLanguage)
    }

    // MARK: - Strict reader and null keys

    private static func decode(_ json: String) throws -> TestProperties {
        try ManifestCodec.decoder.decode(TestProperties.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        #"{"schemaVersion": 2, "inputs": [{"name": "x", "value": 1, "expression": "seed"}]}"#,
        #"{"schemaVersion": 2, "inputs": [{"name": "x"}]}"#,
        #"{"schemaVersion": 2, "sections": [{"id": "s", "name": "S", "inputs": [{"name": "x"}]}]}"#,
        #"{"schemaVersion": 2, "files": [{"name": "a.csv", "dataset": {"file": "b.csv"}}]}"#,
        #"{"schemaVersion": 2, "files": [{"name": "a.ipynb", "starterNotebook": true}, {"name": "b.ipynb", "starterNotebook": true}]}"#,
    ])
    func refusesAnUnclearHandWrittenDocument(_ json: String) {
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test func nullLanguageIsUndeclared() throws {
        let p = try Self.decode(#"{"schemaVersion": 2, "language": null}"#)
        #expect(p.languageDeclaration == .undeclared)
    }

    /// `awards` present, even empty, means the built-in awards were seeded;
    /// `null` means they were not.
    @Test func nullAwardsIsNotSeeded() throws {
        #expect(!(try Self.decode(#"{"schemaVersion": 2, "awards": null}"#)).builtInAchievementsSeeded)
        #expect(try Self.decode(#"{"schemaVersion": 2, "awards": {}}"#).builtInAchievementsSeeded)
    }
}
