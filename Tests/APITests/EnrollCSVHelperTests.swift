// Tests/APITests/EnrollCSVHelperTests.swift
//
// Unit tests for parseUsernamesFromCSV — header detection, quote stripping,
// encoding fallback, and edge cases.

import Testing
@testable import chickadee_server
import Foundation

@Suite struct EnrollCSVHelperTests {

    // MARK: - Basic parsing

    @Test func simpleOneColumnList() {
        let csv = "alice\nbob\ncharlie\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob", "charlie"])
    }

    @Test func multiColumnTakesFirstOnly() {
        let csv = "alice,Alice Smith,alice@example.com\nbob,Bob Jones,bob@example.com\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob"])
    }

    @Test func stripsQuotes() {
        let csv = "\"alice\"\n'bob'\n\"charlie\"\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob", "charlie"])
    }

    @Test func stripsWhitespace() {
        let csv = "  alice  \n  bob  \n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob"])
    }

    @Test func skipsBlankLines() {
        let csv = "alice\n\n\nbob\n\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob"])
    }

    // MARK: - Header detection

    @Test func skipsUsernameHeader() {
        let csv = "username\nalice\nbob\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob"])
    }

    @Test func skipsUserHeader() {
        let csv = "User\nalice\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice"])
    }

    @Test func skipsStudentIdHeader() {
        let csv = "student_id\nalice\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice"])
    }

    @Test func skipsLoginIdHeader() {
        let csv = "\"login_id\",\"name\"\nalice,Alice\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice"])
    }

    @Test func skipsUserIdHeaderWithSpaces() {
        // "user id" → normalized to "userid" → matches
        let csv = "User ID\nalice\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice"])
    }

    @Test func doesNotSkipNonHeaderFirstRow() {
        let csv = "alice\nbob\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob"])
    }

    // MARK: - Edge cases

    @Test func emptyData() {
        #expect(parseUsernamesFromCSV(Data()).isEmpty)
    }

    @Test func onlyHeader() {
        let csv = "username\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)).isEmpty)
    }

    @Test func onlyBlankLines() {
        let csv = "\n\n\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)).isEmpty)
    }

    // swift-corelibs-foundation on Linux does not support .isoLatin1 encoding
    // (String(data:encoding:.isoLatin1) always returns nil), so this test is macOS-only.
    #if !os(Linux)
    @Test func isoLatin1Fallback() {
        // Build the bytes manually: "José,Eng\nAlice,Sci\n" in ISO-8859-1.
        let bytes: [UInt8] = [
            0x4A, 0x6F, 0x73, 0xE9, 0x2C, 0x45, 0x6E, 0x67, 0x0A,  // José,Eng\n
            0x41, 0x6C, 0x69, 0x63, 0x65, 0x2C, 0x53, 0x63, 0x69, 0x0A  // Alice,Sci\n
        ]
        let result = parseUsernamesFromCSV(Data(bytes))
        #expect(result.contains("Alice"), "Expected 'Alice' in results: \(result)")
        #expect(result.count >= 1)
    }
    #endif

    @Test func windowsLineEndings() {
        let csv = "alice\r\nbob\r\ncharlie\r\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob", "charlie"])
    }
}
