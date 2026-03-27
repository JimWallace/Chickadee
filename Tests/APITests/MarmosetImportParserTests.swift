// Tests/APITests/MarmosetImportParserTests.swift
//
// Unit tests for the MarmosetImportParser utility functions.

import XCTest
@testable import chickadee_server
import Foundation
import Core

final class MarmosetImportParserTests: XCTestCase {

    private func makeZip(entries: [(name: String, content: String)]) throws -> String {
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
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("python3 not available or failed to create zip")
        }
        return zipPath
    }

    // MARK: - parseJavaProperties

    func testParseSimpleProperties() {
        let input = "key1=value1\nkey2=value2\n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["key1"], "value1")
        XCTAssertEqual(result["key2"], "value2")
        XCTAssertEqual(result.count, 2)
    }

    func testParseColonSeparator() {
        let input = "key1:value1\nkey2: value2\n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["key1"], "value1")
        XCTAssertEqual(result["key2"], "value2")
    }

    func testParseComments() {
        let input = """
        # This is a comment
        ! This too
        key1=value1
        # Another comment
        key2=value2
        """
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["key1"], "value1")
        XCTAssertEqual(result["key2"], "value2")
    }

    func testParseEmptyLines() {
        let input = "key1=value1\n\n\nkey2=value2\n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result.count, 2)
    }

    func testParseBackslashContinuation() {
        let input = "key1=val1,\\\n  val2,\\\n  val3\nkey2=simple\n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["key1"], "val1,val2,val3")
        XCTAssertEqual(result["key2"], "simple")
    }

    func testParseWhitespaceTrimming() {
        let input = "  key1  =  value1  \n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["key1"], "value1")
    }

    func testParseEqualsInValue() {
        // Only split on first =
        let input = "key1=a=b=c\n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["key1"], "a=b=c")
    }

    func testParseEmptyValue() {
        let input = "key1=\nkey2=value\n"
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["key1"], "")
        XCTAssertEqual(result["key2"], "value")
    }

    func testParseEmptyData() {
        let result = parseJavaProperties(Data())
        XCTAssertTrue(result.isEmpty)
    }

    func testParseTypicalMarmosetTestProperties() {
        let input = """
        # Marmoset test properties
        test.class.public=TestPublicA,TestPublicB
        test.class.release=TestReleaseA
        test.class.secret=TestSecretA,\
          TestSecretB
        build.language=python
        """
        let result = parseJavaProperties(Data(input.utf8))
        XCTAssertEqual(result["test.class.public"], "TestPublicA,TestPublicB")
        XCTAssertEqual(result["test.class.release"], "TestReleaseA")
        XCTAssertEqual(result["test.class.secret"], "TestSecretA,  TestSecretB")
        XCTAssertEqual(result["build.language"], "python")
    }

    // MARK: - parseTestClassList

    func testParseTestClassListSimple() {
        let result = parseTestClassList("TestA,TestB,TestC")
        XCTAssertEqual(result, ["TestA", "TestB", "TestC"])
    }

    func testParseTestClassListWithWhitespace() {
        let result = parseTestClassList("TestA , TestB , TestC")
        XCTAssertEqual(result, ["TestA", "TestB", "TestC"])
    }

    func testParseTestClassListWithNewlines() {
        let result = parseTestClassList("TestA,\n  TestB,\n  TestC")
        XCTAssertEqual(result, ["TestA", "TestB", "TestC"])
    }

    func testParseTestClassListEmpty() {
        let result = parseTestClassList("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseTestClassListSingle() {
        let result = parseTestClassList("OnlyOne")
        XCTAssertEqual(result, ["OnlyOne"])
    }

    func testParseTestClassListTrailingComma() {
        let result = parseTestClassList("TestA,TestB,")
        XCTAssertEqual(result, ["TestA", "TestB"])
    }

    // MARK: - extractTitleFromProjectOut

    func testExtractTitleFromValidData() {
        // Encode a 2-byte big-endian length + UTF-8 string
        var data = Data()
        let title = "Assignment 1 BMI Calculator"
        let titleBytes = Array(title.utf8)
        data.append(UInt8(titleBytes.count >> 8))
        data.append(UInt8(titleBytes.count & 0xFF))
        data.append(contentsOf: titleBytes)
        // Add some padding bytes before/after
        var fullData = Data(repeating: 0x00, count: 10)
        fullData.append(data)
        fullData.append(Data(repeating: 0x00, count: 10))

        let result = extractTitleFromProjectOut(fullData)
        XCTAssertEqual(result, "Assignment 1 BMI Calculator")
    }

    func testExtractTitlePrefersSpaceContaining() {
        var data = Data()
        // First: a capitalized word without space
        let word = "SomeClass"
        let wordBytes = Array(word.utf8)
        data.append(UInt8(wordBytes.count >> 8))
        data.append(UInt8(wordBytes.count & 0xFF))
        data.append(contentsOf: wordBytes)
        // Then: a title with a space
        let title = "Project One"
        let titleBytes = Array(title.utf8)
        data.append(UInt8(titleBytes.count >> 8))
        data.append(UInt8(titleBytes.count & 0xFF))
        data.append(contentsOf: titleBytes)

        let result = extractTitleFromProjectOut(data)
        XCTAssertEqual(result, "Project One")
    }

    func testExtractTitleRejectsNumbers() {
        var data = Data()
        let number = "12345"
        let bytes = Array(number.utf8)
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)

        let result = extractTitleFromProjectOut(data)
        XCTAssertNil(result)
    }

    func testExtractTitleRejectsDotPaths() {
        var data = Data()
        let path = "com.example.Test"
        let bytes = Array(path.utf8)
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)

        let result = extractTitleFromProjectOut(data)
        XCTAssertNil(result)
    }

    func testExtractTitleRejectsSlashPaths() {
        var data = Data()
        let path = "src/main/Test"
        let bytes = Array(path.utf8)
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)

        let result = extractTitleFromProjectOut(data)
        XCTAssertNil(result)
    }

    func testExtractTitleEmptyData() {
        let result = extractTitleFromProjectOut(Data())
        XCTAssertNil(result)
    }

    func testExtractTitleTooShortStrings() {
        // String of length 2 should be rejected (minimum is 3)
        var data = Data()
        let short = "Hi"
        let bytes = Array(short.utf8)
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)

        let result = extractTitleFromProjectOut(data)
        XCTAssertNil(result)
    }

    // MARK: - convertToChickadeeManifest

    func testConvertManifestBasic() throws {
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

        XCTAssertEqual(decoded["schemaVersion"] as? Int, 1)
        XCTAssertEqual(decoded["gradingMode"] as? String, "worker")
        XCTAssertEqual(decoded["timeLimitSeconds"] as? Int, 10)
        XCTAssertEqual(decoded["starterNotebook"] as? String, "assignment.ipynb")

        let suites = decoded["testSuites"] as! [[String: String]]
        XCTAssertEqual(suites.count, 2)
        XCTAssertTrue(suites.contains { $0["tier"] == "public" && $0["script"] == "test_public.sh" })
        XCTAssertTrue(suites.contains { $0["tier"] == "release" && $0["script"] == "test_release.sh" })
    }

    func testConvertManifestAllTiers() throws {
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
        XCTAssertEqual(suites.count, 5)
        let pubCount = suites.filter { $0["tier"] == "public" }.count
        let relCount = suites.filter { $0["tier"] == "release" }.count
        let secCount = suites.filter { $0["tier"] == "secret" }.count
        XCTAssertEqual(pubCount, 2)
        XCTAssertEqual(relCount, 1)
        XCTAssertEqual(secCount, 2)
    }

    func testConvertManifestEmptyTests() throws {
        let project = MarmosetProject(
            number: 1,
            publicTests: [],
            releaseTests: [],
            secretTests: [],
            hasMakefile: false,
            suggestedTitle: nil
        )
        let json = try convertToChickadeeManifest(project: project)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]

        let suites = decoded["testSuites"] as! [[String: String]]
        XCTAssertEqual(suites.count, 0)
    }

    func testConvertManifestProducesValidTestProperties() throws {
        let project = MarmosetProject(
            number: 1,
            publicTests: ["test.sh"],
            releaseTests: [],
            secretTests: [],
            hasMakefile: false,
            suggestedTitle: nil
        )
        let json = try convertToChickadeeManifest(project: project)
        // Verify it round-trips through TestProperties decoder
        let props = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        XCTAssertEqual(props.schemaVersion, 1)
        XCTAssertEqual(props.testSuites.count, 1)
        XCTAssertEqual(props.testSuites.first?.script, "test.sh")
        XCTAssertEqual(props.testSuites.first?.tier, .pub)
        XCTAssertEqual(props.timeLimitSeconds, 10)
    }

    // MARK: - MarmosetProject struct

    func testMarmosetProjectStoresAllFields() {
        let p = MarmosetProject(
            number: 3,
            publicTests: ["a", "b"],
            releaseTests: ["c"],
            secretTests: [],
            hasMakefile: true,
            suggestedTitle: "Test Project"
        )
        XCTAssertEqual(p.number, 3)
        XCTAssertEqual(p.publicTests, ["a", "b"])
        XCTAssertEqual(p.releaseTests, ["c"])
        XCTAssertTrue(p.secretTests.isEmpty)
        XCTAssertTrue(p.hasMakefile)
        XCTAssertEqual(p.suggestedTitle, "Test Project")
    }

    func testFirstNotebookInZipFindsNestedNotebook() throws {
        let zipPath = try makeZip(entries: [
            ("starter-files/Lab 1.ipynb", "{}"),
            ("starter-files/readme.txt", "hello")
        ])
        defer { try? FileManager.default.removeItem(atPath: zipPath) }

        XCTAssertEqual(try firstNotebookInZip(zipPath: zipPath), "Lab 1.ipynb")
        let extracted = try extractNotebookFromZip(zipPath: zipPath, filename: "Lab 1.ipynb")
        XCTAssertEqual(String(data: try XCTUnwrap(extracted), encoding: .utf8), "{}")
    }

    func testExtractSolutionFromCanonicalZipHandlesNestedEntry() throws {
        let zipPath = try makeZip(entries: [
            ("canonical/solution.py", "print('ok')\n")
        ])
        defer { try? FileManager.default.removeItem(atPath: zipPath) }

        let solution = try extractSolutionFromCanonicalZip(zipPath: zipPath)
        XCTAssertEqual(solution?.originalFilename, "solution.py")
        XCTAssertEqual(solution?.ext, "py")
        XCTAssertEqual(String(data: try XCTUnwrap(solution?.data), encoding: .utf8), "print('ok')\n")
    }
}
