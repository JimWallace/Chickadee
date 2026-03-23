// Tests/APITests/EnrollCSVHelperTests.swift
//
// Unit tests for parseUsernamesFromCSV — header detection, quote stripping,
// encoding fallback, and edge cases.

import XCTest
@testable import chickadee_server
import Foundation

final class EnrollCSVHelperTests: XCTestCase {

    // MARK: - Basic parsing

    func testSimpleOneColumnList() {
        let csv = "alice\nbob\ncharlie\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob", "charlie"])
    }

    func testMultiColumnTakesFirstOnly() {
        let csv = "alice,Alice Smith,alice@example.com\nbob,Bob Jones,bob@example.com\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob"])
    }

    func testStripsQuotes() {
        let csv = "\"alice\"\n'bob'\n\"charlie\"\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob", "charlie"])
    }

    func testStripsWhitespace() {
        let csv = "  alice  \n  bob  \n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob"])
    }

    func testSkipsBlankLines() {
        let csv = "alice\n\n\nbob\n\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob"])
    }

    // MARK: - Header detection

    func testSkipsUsernameHeader() {
        let csv = "username\nalice\nbob\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob"])
    }

    func testSkipsUserHeader() {
        let csv = "User\nalice\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice"])
    }

    func testSkipsStudentIdHeader() {
        let csv = "student_id\nalice\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice"])
    }

    func testSkipsLoginIdHeader() {
        let csv = "\"login_id\",\"name\"\nalice,Alice\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice"])
    }

    func testSkipsUserIdHeaderWithSpaces() {
        // "user id" → normalized to "userid" → matches
        let csv = "User ID\nalice\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice"])
    }

    func testDoesNotSkipNonHeaderFirstRow() {
        let csv = "alice\nbob\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob"])
    }

    // MARK: - Edge cases

    func testEmptyData() {
        let result = parseUsernamesFromCSV(Data())
        XCTAssertTrue(result.isEmpty)
    }

    func testOnlyHeader() {
        let csv = "username\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertTrue(result.isEmpty)
    }

    func testOnlyBlankLines() {
        let csv = "\n\n\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertTrue(result.isEmpty)
    }

    func testISOLatin1Fallback() {
        // On macOS, String(data:encoding:.utf8) returns nil for invalid UTF-8,
        // triggering the isoLatin1 fallback. On Linux (swift-corelibs-foundation),
        // .utf8 may succeed with replacement characters instead.
        // This test verifies the function handles Latin-1 encoded data without
        // crashing and returns reasonable results on all platforms.
        //
        // Build the bytes manually: "José,Eng\nAlice,Sci\n" in ISO-8859-1.
        // 0x4A=J 0x6F=o 0x73=s 0xE9=é(Latin-1) 0x2C=, ...
        let bytes: [UInt8] = [
            0x4A, 0x6F, 0x73, 0xE9, 0x2C, 0x45, 0x6E, 0x67, 0x0A,  // José,Eng\n
            0x41, 0x6C, 0x69, 0x63, 0x65, 0x2C, 0x53, 0x63, 0x69, 0x0A  // Alice,Sci\n
        ]
        let data = Data(bytes)
        let result = parseUsernamesFromCSV(data)
        // "Alice" is pure ASCII on line 2 and should always parse correctly
        // regardless of whether the UTF-8 or Latin-1 path is taken.
        XCTAssertTrue(result.contains("Alice"), "Expected 'Alice' in results: \(result)")
        XCTAssertGreaterThanOrEqual(result.count, 1)
    }

    func testWindowsLineEndings() {
        let csv = "alice\r\nbob\r\ncharlie\r\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob", "charlie"])
    }
}
