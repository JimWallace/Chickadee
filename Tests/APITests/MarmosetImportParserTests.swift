// Tests/APITests/MarmosetImportParserTests.swift
//
// Unit tests for the MarmosetImportParser utility functions.

import Core
import Fluent
import Foundation
import Testing

@testable import chickadee_server

@Suite struct MarmosetImportParserTests {

    /// Creates a zip archive via Python's zipfile module.
    /// Returns nil (and the calling test should return early) if python3 is not available.
    private func makeZip(entries: [(name: String, content: String)]) throws -> String? {
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmoset-parser-\(UUID().uuidString).zip")
            .path
        let entriesCode = entries.map { entry in
            "z.writestr(\(entry.name.debugDescription), \(entry.content.debugDescription))"
        }.joined(separator: "\n    ")
        let script = """
            import zipfile
            with zipfile.ZipFile(\(zipPath.debugDescription), "w") as z:
                \(entriesCode)
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return zipPath
    }

    // MARK: - parseJavaProperties

    @Test func parseSimpleProperties() {
        let input = "key1=value1\nkey2=value2\n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
        #expect(result.count == 2)
    }

    @Test func parseColonSeparator() {
        let input = "key1:value1\nkey2: value2\n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test func parseComments() {
        let input = """
            # This is a comment
            ! This too
            key1=value1
            # Another comment
            key2=value2
            """
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result.count == 2)
        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test func parseEmptyLines() {
        let input = "key1=value1\n\n\nkey2=value2\n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result.count == 2)
    }

    @Test func parseBackslashContinuation() {
        let input = "key1=val1,\\\n  val2,\\\n  val3\nkey2=simple\n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["key1"] == "val1,val2,val3")
        #expect(result["key2"] == "simple")
    }

    @Test func parseWhitespaceTrimming() {
        let input = "  key1  =  value1  \n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["key1"] == "value1")
    }

    @Test func parseEqualsInValue() {
        // Only split on first =
        let input = "key1=a=b=c\n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["key1"] == "a=b=c")
    }

    @Test func parseEmptyValue() {
        let input = "key1=\nkey2=value\n"
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["key1"] == "")
        #expect(result["key2"] == "value")
    }

    @Test func parseEmptyData() {
        #expect(parseJavaProperties(Data()).isEmpty)
    }

    @Test func parseTypicalMarmosetTestProperties() {
        let input = """
            # Marmoset test properties
            test.class.public=TestPublicA,TestPublicB
            test.class.release=TestReleaseA
            test.class.secret=TestSecretA,\
              TestSecretB
            build.language=python
            """
        let result = parseJavaProperties(Data(input.utf8))
        #expect(result["test.class.public"] == "TestPublicA,TestPublicB")
        #expect(result["test.class.release"] == "TestReleaseA")
        #expect(result["test.class.secret"] == "TestSecretA,  TestSecretB")
        #expect(result["build.language"] == "python")
    }

    // MARK: - parseTestClassList

    @Test func parseTestClassListSimple() {
        #expect(parseTestClassList("TestA,TestB,TestC") == ["TestA", "TestB", "TestC"])
    }

    @Test func parseTestClassListWithWhitespace() {
        #expect(parseTestClassList("TestA , TestB , TestC") == ["TestA", "TestB", "TestC"])
    }

    @Test func parseTestClassListWithNewlines() {
        #expect(parseTestClassList("TestA,\n  TestB,\n  TestC") == ["TestA", "TestB", "TestC"])
    }

    @Test func parseTestClassListEmpty() {
        #expect(parseTestClassList("").isEmpty)
    }

    @Test func parseTestClassListSingle() {
        #expect(parseTestClassList("OnlyOne") == ["OnlyOne"])
    }

    @Test func parseTestClassListTrailingComma() {
        #expect(parseTestClassList("TestA,TestB,") == ["TestA", "TestB"])
    }

    // MARK: - extractTitleFromProjectOut

    private func makeTitleData(_ title: String) -> Data {
        var data = Data()
        let bytes = Array(title.utf8)
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)
        return data
    }

    @Test func extractTitleFromValidData() {
        var fullData = Data(repeating: 0x00, count: 10)
        fullData.append(makeTitleData("Assignment 1 BMI Calculator"))
        fullData.append(Data(repeating: 0x00, count: 10))
        #expect(extractTitleFromProjectOut(fullData) == "Assignment 1 BMI Calculator")
    }

    @Test func extractTitlePrefersSpaceContaining() {
        var data = makeTitleData("SomeClass")
        data.append(makeTitleData("Project One"))
        #expect(extractTitleFromProjectOut(data) == "Project One")
    }

    @Test func extractTitleRejectsNumbers() {
        #expect(extractTitleFromProjectOut(makeTitleData("12345")) == nil)
    }

    @Test func extractTitleRejectsDotPaths() {
        #expect(extractTitleFromProjectOut(makeTitleData("com.example.Test")) == nil)
    }

    @Test func extractTitleRejectsSlashPaths() {
        #expect(extractTitleFromProjectOut(makeTitleData("src/main/Test")) == nil)
    }

    @Test func extractTitleEmptyData() {
        #expect(extractTitleFromProjectOut(Data()) == nil)
    }

    @Test func extractTitleTooShortStrings() {
        // Strings of length 2 should be rejected (minimum is 3).
        #expect(extractTitleFromProjectOut(makeTitleData("Hi")) == nil)
    }

    // MARK: - convertToChickadeeManifest

    @Test func convertManifestBasic() throws {
        let project = MarmosetProject(
            number: 1,
            publicTests: ["test_public.sh"],
            releaseTests: ["test_release.sh"],
            secretTests: [],
            hasMakefile: false,
            suggestedTitle: nil
        )
        let json = try convertToChickadeeManifest(project: project)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]

        #expect(decoded["schemaVersion"] as? Int == 1)
        #expect(decoded["gradingMode"] as? String == "worker")
        #expect(decoded["timeLimitSeconds"] as? Int == 10)
        #expect(decoded["starterNotebook"] as? String == "assignment.ipynb")

        let suites = decoded["testSuites"] as! [[String: String]]
        #expect(suites.count == 2)
        #expect(suites.contains { $0["tier"] == "public" && $0["script"] == "test_public.sh" })
        #expect(suites.contains { $0["tier"] == "release" && $0["script"] == "test_release.sh" })
    }

    @Test func convertManifestAllTiers() throws {
        let project = MarmosetProject(
            number: 2,
            publicTests: ["pub1.sh", "pub2.sh"],
            releaseTests: ["rel1.sh"],
            secretTests: ["sec1.sh", "sec2.sh"],
            hasMakefile: true,
            suggestedTitle: "Project 2"
        )
        let json = try convertToChickadeeManifest(project: project)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let suites = decoded["testSuites"] as! [[String: String]]

        #expect(suites.count == 5)
        #expect(suites.filter { $0["tier"] == "public" }.count == 2)
        #expect(suites.filter { $0["tier"] == "release" }.count == 1)
        #expect(suites.filter { $0["tier"] == "secret" }.count == 2)
    }

    @Test func convertManifestEmptyTests() throws {
        let project = MarmosetProject(
            number: 1, publicTests: [], releaseTests: [], secretTests: [],
            hasMakefile: false, suggestedTitle: nil
        )
        let json = try convertToChickadeeManifest(project: project)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let suites = decoded["testSuites"] as! [[String: String]]
        #expect(suites.isEmpty)
    }

    @Test func convertManifestProducesValidTestProperties() throws {
        let project = MarmosetProject(
            number: 1,
            publicTests: ["test.sh"],
            releaseTests: [],
            secretTests: [],
            hasMakefile: false,
            suggestedTitle: nil
        )
        let json = try convertToChickadeeManifest(project: project)
        let props = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))

        #expect(props.schemaVersion == 1)
        #expect(props.testSuites.count == 1)
        #expect(props.testSuites.first?.script == "test.sh")
        #expect(props.testSuites.first?.tier == .pub)
        #expect(props.timeLimitSeconds == 10)
    }

    // MARK: - MarmosetProject struct

    @Test func marmosetProjectStoresAllFields() {
        let p = MarmosetProject(
            number: 3,
            publicTests: ["a", "b"],
            releaseTests: ["c"],
            secretTests: [],
            hasMakefile: true,
            suggestedTitle: "Test Project"
        )
        #expect(p.number == 3)
        #expect(p.publicTests == ["a", "b"])
        #expect(p.releaseTests == ["c"])
        #expect(p.secretTests.isEmpty)
        #expect(p.hasMakefile)
        #expect(p.suggestedTitle == "Test Project")
    }

    @Test func firstNotebookInZipFindsNestedNotebook() throws {
        guard
            let zipPath = try makeZip(entries: [
                ("starter-files/Lab 1.ipynb", "{}"),
                ("starter-files/readme.txt", "hello"),
            ])
        else { return }
        defer { try? FileManager.default.removeItem(atPath: zipPath) }

        #expect(try firstNotebookInZip(zipPath: zipPath) == "Lab 1.ipynb")
        let extracted = try extractNotebookFromZip(zipPath: zipPath, filename: "Lab 1.ipynb")
        #expect(String(data: try #require(extracted), encoding: .utf8) == "{}")
    }

    @Test func extractSolutionFromCanonicalZipHandlesNestedEntry() throws {
        guard
            let zipPath = try makeZip(entries: [
                ("canonical/solution.py", "print('ok')\n")
            ])
        else { return }
        defer { try? FileManager.default.removeItem(atPath: zipPath) }

        let solution = try extractSolutionFromCanonicalZip(zipPath: zipPath)
        #expect(solution?.originalFilename == "solution.py")
        #expect(solution?.ext == "py")
        #expect(String(data: try #require(solution?.data), encoding: .utf8) == "print('ok')\n")
    }
}
