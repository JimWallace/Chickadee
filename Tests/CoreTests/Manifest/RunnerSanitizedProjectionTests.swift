import Foundation
import Testing

@testable import Core

// Pins the exact set of top-level JSON keys a runner sees in the manifest
// produced by `TestProperties.runnerSanitized()`.  The projection strips
// server-only fields by memberwise omission, which means a newly added
// `TestProperties` field ships to every runner *by default* — silently —
// unless the author decides otherwise.  This test turns that silent default
// into an explicit decision: adding a field fails it until the author either
// strips the field in `runnerSanitized()` or deliberately forwards it (and
// adds its key to `expectedRunnerVisibleKeys`).

struct RunnerSanitizedProjectionTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Every key `TestProperties.encode(to:)` emits for the sanitized
    /// `fullyPopulatedManifest()`.  An empty list and a false flag are
    /// omitted from the encoding (#1655), so a field `runnerSanitized()`
    /// strips (`testItems`, the mirrored legacy `patternFamilies` /
    /// `notebookChecks`, `globalExpressions`, `datasets`, `graderOnlyFiles`,
    /// `achievements`, …) is absent rather than empty, and a field it
    /// forwards shows up because the fixture populates every field.
    private let expectedRunnerVisibleKeys: Set<String> = [
        "schemaVersion",
        "gradingMode",
        // Forwarded deliberately, like gradingMode: the runner reads neither
        // today, but a runner-side re-read of the manifest must resolve the
        // same effectiveGradingMode the server did — losing submissionMode
        // would flip an upload+browser bundle back to browser there.
        "submissionMode",
        // Forwarded deliberately: the runner reads the language off
        // `Job.language`, but a manifest that silently lost it would resolve
        // differently on any path that re-reads the runner-facing copy, and
        // `languageDeclared` is what lets a runner tell "declared to have no
        // language" from "nobody has declared one".
        "language",
        "languageDeclared",
        "requiredFiles",
        "testSuites",
        "timeLimitSeconds",
        "makefile",
        "starterNotebook",
        "sections",
        "globalVariables",
    ]

    /// A `TestProperties` with **every** field populated with a non-default
    /// value, so every encodable key (including the `encodeIfPresent` pair,
    /// `makefile` / `starterNotebook`, and the flags and blocks a default
    /// value would omit) is exercised by the projection. A field left at its
    /// default here is a field the pin cannot see (#1747).
    private func fullyPopulatedManifest() -> TestProperties {
        TestProperties(
            schemaVersion: 2,
            gradingMode: .browser,
            submissionMode: .uploadOnly,
            githubSubmission: true,
            githubStatusChecks: true,
            requiredFiles: ["warmup.py"],
            testSuites: [
                TestSuiteEntry(
                    tier: .release, script: "test_a.py", name: "Test A",
                    dependsOn: ["test_b.py"], points: 3,
                    generatedBy: "fam",
                    sectionID: "sec1", hint: "look closer",
                    timeLimitSeconds: 20)
            ],
            timeLimitSeconds: 30,
            makefile: MakefileConfig(target: "all"),
            starterNotebook: "assignment.ipynb",
            language: .r,
            languageDeclared: true,
            // Non-nil so the strip is actually exercised: runnerSanitized() must
            // drop this (server-side gate), keeping the key out of the pinned set.
            minimumRunnerVersion: "0.5.0",
            // A window and an opponent file, so the whole block is present and
            // the strip (an older runner must never decode a kind it predates)
            // is exercised rather than vacuous.
            activity: ClassActivity(
                kind: .beatTheInstructor, leaderboardVisibility: .visible, opponentFile: "bot.py",
                window: LiveSessionWindow(
                    opensAtISO: "2026-01-05T14:00:00Z", closesAtISO: "2026-01-05T16:00:00Z")),
            patternFamilies: [
                PatternFamily(
                    id: "fam", name: "Family", kind: .boundaryEquality,
                    functionName: "f", paramNames: ["x"],
                    defaults: PatternDefaults(tier: .pub, points: 2, hint: "h"),
                    cases: [
                        PatternCase(
                            key: "01", label: "one",
                            args: [.int(1)], expected: .string("ok"))
                    ],
                    variables: [FamilyVariable(name: "v", value: .int(1))],
                    dependsOn: ["test_b.py"])
            ],
            notebookChecks: [
                NotebookCheck(
                    id: "chk", kind: .dataFrameShape,
                    variable: "df", expectedRows: 1, expectedCols: 2)
            ],
            sections: [
                TestSuiteSection(
                    id: "sec1", name: "Section 1",
                    variables: [FamilyVariable(name: "sv", value: .int(2))],
                    expressions: [
                        PersonalizationExpression(name: "se", expression: "seed + 1")
                    ])
            ],
            globalVariables: [FamilyVariable(name: "gv", value: .int(3))],
            globalExpressions: [
                PersonalizationExpression(name: "ge", expression: "seed * 2")
            ],
            datasets: [DatasetSpec(file: "pool.csv", kind: .rowSample, sampleSize: 5)],
            graderOnlyFiles: ["holdout.csv"],
            achievements: [
                Achievement(
                    id: "ach", name: "Ach", scope: .individual,
                    conditions: [
                        AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)
                    ],
                    reward: AchievementReward(type: .badge, label: "B"))
            ],
            disabledBuiltInAwardIDs: ["first-try-perfect"],
            builtInAchievementsSeeded: true
        )
    }

    @Test func runnerSanitizedTopLevelKeySetIsPinned() throws {
        let sanitized = fullyPopulatedManifest().runnerSanitized()
        let data = try encoder.encode(sanitized)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(object.keys)

        #expect(
            keys == expectedRunnerVisibleKeys,
            """
            The runner-visible top-level key set of runnerSanitized() changed \
            (added: \(keys.subtracting(expectedRunnerVisibleKeys).sorted()), \
            removed: \(expectedRunnerVisibleKeys.subtracting(keys).sorted())). \
            runnerSanitized() strips fields by memberwise omission, so a new \
            TestProperties field is forwarded to every runner by default. \
            Decide explicitly: either strip the field in runnerSanitized() \
            (server-only concern — the usual answer; see datasets / \
            graderOnlyFiles / achievements), or, if runners genuinely need \
            it, forward it deliberately, populate it in fullyPopulatedManifest() \
            and add its key to expectedRunnerVisibleKeys in this test.
            """)
    }
}
