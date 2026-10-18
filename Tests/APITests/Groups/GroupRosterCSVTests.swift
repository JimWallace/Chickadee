// Tests/APITests/Groups/GroupRosterCSVTests.swift
//
// Reading a CSV file of students and their groups (docs/lab-groups.md,
// slice 1): the two accepted shapes, and the files that are refused.

import Foundation
import Testing

@testable import APIServer

@Suite struct GroupRosterCSVTests {

    private func parse(_ text: String) throws -> GroupRosterCSV.Parsed {
        try GroupRosterCSV.parse(Data(text.utf8))
    }

    private func refusal(_ text: String) -> CourseGroupError? {
        do {
            _ = try parse(text)
            return nil
        } catch let error as CourseGroupError {
            return error
        } catch {
            return nil
        }
    }

    @Test func readsTwoColumnsWithNoHeader() throws {
        let parsed = try parse("ada,Lab 101\nalan,Lab 102\n")
        #expect(parsed.groupByUsername == ["ada": "Lab 101", "alan": "Lab 102"])
        #expect(parsed.usernames == ["ada", "alan"])
    }

    /// The LEARN Groups export: a header row, the columns in another order,
    /// quoted cells, and a "Group Category Name" column that must not be read
    /// as the group.
    @Test func readsTheLEARNGroupsExport() throws {
        let text = """
            Group Category Name,Group Name,Group Code,Username,Org Defined ID,"Last Name, First"\r
            Lab sections,Lab 101,L101,ada,20001234,"Lovelace, Ada"\r
            Lab sections,Lab 102,L102,ALAN,20005678,"Turing, Alan"\r

            """
        let parsed = try parse(text)
        #expect(parsed.groupByUsername == ["ada": "Lab 101", "alan": "Lab 102"])
    }

    @Test func ignoresAByteOrderMark() throws {
        let parsed = try parse("\u{FEFF}username,group\nada,Lab 101\n")
        #expect(parsed.groupByUsername == ["ada": "Lab 101"])
    }

    @Test func aBlankGroupPutsTheStudentInNoGroup() throws {
        let parsed = try parse("username,group\nada,Lab 101\nalan,\n")
        #expect(parsed.groupByUsername == ["ada": "Lab 101"])
        #expect(parsed.usernames == ["ada", "alan"])
    }

    @Test func theSameGroupTwiceIsOneRow() throws {
        let parsed = try parse("ada,Lab 101\nADA,lab 101\n")
        #expect(parsed.groupByUsername == ["ada": "Lab 101"])
    }

    @Test func aStudentInTwoGroupsIsRefused() {
        #expect(refusal("ada,Lab 101\nalan,Lab 101\nada,Lab 102\n") == .conflictingRows(usernames: ["ada"]))
    }

    @Test func aHeaderWithNoGroupColumnIsRefused() {
        #expect(refusal("username,email\nada,ada@example.com\n") == .missingColumns)
    }

    @Test func oneColumnWithNoHeaderIsRefused() {
        #expect(refusal("ada\nalan\n") == .missingColumns)
    }

    @Test func anEmptyFileIsRefused() {
        #expect(refusal("\n\n") == .emptyFile)
        #expect(refusal("username,group\n") == .emptyFile)
    }
}
