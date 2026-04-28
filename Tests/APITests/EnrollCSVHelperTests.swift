// Tests/APITests/EnrollCSVHelperTests.swift
//
// Unit tests for parseUsernamesFromCSV — header detection, quote stripping,
// encoding fallback, and edge cases.

import Testing
@testable import chickadee_server
import Fluent
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

    // MARK: - Brightspace / D2L gradebook export shape

    @Test func brightspaceGradebookExportFiltersTestAccounts() {
        // The dotted `#<digits>.<rest>` form is reserved for Brightspace
        // gradebook test accounts.  v0.4.128 onwards drops them entirely
        // so they don't pollute a real class roster — instructors uploading
        // an export expect only actual class members to enrol.
        let csv = """
        OrgDefinedId,Username,End-of-Line Indicator
        #174667.teststudent1,#174667.teststudent1,#
        #174667.teststudent2,#174667.teststudent2,#
        #174667.alice,#174667.alice,#
        """
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == [])
    }

    @Test func brightspacePrefersUsernameColumnWhenDifferent() {
        // When the OrgDefinedId column has the prefixed form but the
        // Username column has the bare username, prefer the Username column.
        // (Both `#174667.alice` rows in OrgDefinedId would otherwise be
        // skipped as test accounts; the Username column has the real
        // bare username, which parses cleanly.)
        let csv = """
        OrgDefinedId,Username,End-of-Line Indicator
        #174667.alice,alice,#
        #174667.bob,bob,#
        """
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob"])
    }

    @Test func brightspaceTestAccountsAreSkippedOnSingleColumn() {
        // Same test-account filter applies even without a header, for
        // instructors who paste a column of dotted-form values.
        let csv = "#174667.alice\n#174667.bob\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == [])
    }

    @Test func stripsBareHashPrefix() {
        // Brightspace prepends `#` to every OrgDefinedId / Username cell
        // (an Excel-anti-coercion hack) — even when the value isn't in
        // the dotted test-account form.  Pre-v0.4.128 these fell through
        // unchanged and were then rejected for containing `#`.  Now we
        // strip the leading hash; the rest goes through username
        // validation as usual.
        let csv = "#alice\n#bob.lastname\n#20878497\n"
        #expect(parseUsernamesFromCSV(Data(csv.utf8)) == ["alice", "bob.lastname", "20878497"])
    }

    @Test func brightspaceRealWorldClassExportFiltersTestAccountsAndKeepsStudents() {
        // Captured shape from a real UWaterloo HLTH 230 export, abridged.
        // The Username column carries bare `#<questname>` for real
        // students and `#<digits>.<name>` for gradebook test accounts;
        // v0.4.128 enrols the real students and silently drops the test
        // accounts.  Pre-v0.4.128 the inverse happened (bug): only the
        // dotted test accounts were accepted, every real student was
        // rejected for containing `#`.
        let csv = """
        OrgDefinedId,Username,End-of-Line Indicator
        #174667.teststudent1,#174667.teststudent1,#
        #174667.teststudent2,#174667.teststudent2,#
        #20878497,#mj39lee,#
        #20940945,#c7quan,#
        #21204837,#zsmskmak,#
        """
        let parsed = parseUsernamesFromCSV(Data(csv.utf8))
        #expect(parsed == ["mj39lee", "c7quan", "zsmskmak"])
    }
}
