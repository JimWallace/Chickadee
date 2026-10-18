// Tests/APITests/Grading/BrowserRunnerManifestJSONTests.swift
//
// `GET /api/v1/browser-runner/testsetups/:id/manifest` is fetched from a
// student's browser.  It must serve the runner contract (`RunnerManifest`)
// and nothing more: the stored manifest also holds `=` expression source
// (which can call the reference solution), family and check specs with
// reference implementations and expected values, dataset specs and
// grader-only file names.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct BrowserRunnerManifestJSONTests {

    /// Authoring data in every field that must stay on the server, with a
    /// marker string in each so a leak shows in the served bytes.
    static let stored = TestProperties(
        gradingMode: .browser,
        githubSubmission: true,
        githubStarterRepository: "org/LEAK-github",
        requiredFiles: ["main.py"],
        testSuites: [
            TestSuiteEntry(
                tier: .release, script: "releasetest_fam_01.py", name: "Case one",
                dependsOn: ["test_build.py"], points: 3, generatedBy: "fam", sectionID: "s1",
                hint: "a hint", timeLimitSeconds: 7)
        ],
        timeLimitSeconds: 12,
        language: .python, languageDeclared: true,
        minimumRunnerVersion: "0.5.0",
        patternFamilies: [
            PatternFamily(
                id: "fam", name: "Family", kind: .differential, functionName: "f",
                paramNames: ["x"],
                cases: [PatternCase(key: "01", label: "one", args: [.int(1)], expected: .string("LEAK-expected"))],
                referenceImplementation: "def f(x): return 'LEAK-reference'")
        ],
        notebookChecks: [
            NotebookCheck(id: "chk", kind: .dataFrameEquality, variable: "df", expectedCSV: "a\nLEAK-csv\n")
        ],
        sections: [
            TestSuiteSection(
                id: "s1", name: "Part 1",
                variables: [FamilyVariable(name: "limit", value: .int(5))],
                expressions: [PersonalizationExpression(name: "n", expression: "solution.LEAK_section(seed)")])
        ],
        globalExpressions: [PersonalizationExpression(name: "g", expression: "solution.LEAK_global(seed)")],
        datasets: [DatasetSpec(file: "LEAK-pool.csv", sampleSize: 4)],
        graderOnlyFiles: ["LEAK-holdout.csv"],
        disabledBuiltInAwardIDs: ["LEAK-award"])

    private static func served() throws -> (text: String, object: [String: Any]) {
        let text = try #require(browserRunnerManifestJSON(try encodeManifest(stored)))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return (text, object)
    }

    @Test func noAuthoringDataIsServed() throws {
        let text = try Self.served().text
        #expect(!text.contains("LEAK"), "the browser manifest carries authoring data: \(text)")
    }

    @Test func theFieldsTheBrowserReadsAreServed() throws {
        let object = try Self.served().object
        #expect(object["timeLimitSeconds"] as? Int == 12)
        let sections = try #require(object["sections"] as? [[String: Any]])
        #expect(sections.first?["id"] as? String == "s1")
        #expect(sections.first?["name"] as? String == "Part 1")
        let entry = try #require((object["testSuites"] as? [[String: Any]])?.first)
        #expect(entry["script"] as? String == "releasetest_fam_01.py")
        #expect(entry["tier"] as? String == "release")
        #expect(entry["name"] as? String == "Case one")
        #expect(entry["dependsOn"] as? [String] == ["test_build.py"])
        #expect(entry["points"] as? Int == 3)
        #expect(entry["timeLimitSeconds"] as? Int == 7)
        #expect(entry["sectionID"] as? String == "s1")
    }

    /// The served body is the same v1 bytes the native runner receives.
    @Test func theBodyIsTheRunnerContract() throws {
        let expected = try ManifestCodec.stableEncoder.encode(Self.stored.runnerManifest())
        #expect(try Self.served().text == String(bytes: expected, encoding: .utf8))
    }

    @Test func aManifestThatDoesNotDecodeServesNothing() {
        #expect(browserRunnerManifestJSON("not json") == nil)
    }
}
