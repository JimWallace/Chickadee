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
        // Create data that is valid ISO-8859-1 but not valid UTF-8.
        // Byte sequence 0xC0 0x20 is invalid UTF-8 (overlong), forcing the
        // Latin-1 fallback path on all platforms.
        var bytes: [UInt8] = Array("user_alice".utf8)
        bytes.append(0xC0)  // invalid UTF-8 start byte
        bytes.append(0x20)  // space (not a valid continuation byte)
        bytes.append(contentsOf: Array("\nbob\n".utf8))
        let data = Data(bytes)
        let result = parseUsernamesFromCSV(data)
        // The first line contains the invalid bytes but should still parse via Latin-1.
        // "bob" should always be present regardless of how the first line is handled.
        XCTAssertTrue(result.contains("bob"), "Expected 'bob' in results: \(result)")
    }

    func testWindowsLineEndings() {
        let csv = "alice\r\nbob\r\ncharlie\r\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob", "charlie"])
    }
}
