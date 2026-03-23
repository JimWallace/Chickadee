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
        // Create data that is valid ISO-8859-1 but not valid UTF-8
        // The é in "José" encoded as ISO-8859-1 is byte 0xE9
        var bytes: [UInt8] = Array("Jos".utf8)
        bytes.append(0xE9)  // é in ISO-8859-1
        bytes.append(contentsOf: Array("\n".utf8))
        let data = Data(bytes)
        let result = parseUsernamesFromCSV(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasPrefix("Jos"))
    }

    func testWindowsLineEndings() {
        let csv = "alice\r\nbob\r\ncharlie\r\n"
        let result = parseUsernamesFromCSV(Data(csv.utf8))
        XCTAssertEqual(result, ["alice", "bob", "charlie"])
    }
}
