// Tests/CoreTests/DatasetDictionaryTests.swift
//
// The data dictionary of a library dataset version
// (docs/datasets-course-library.md, D7): the profile of an upload, the type
// inference, the prose carried onto a new version, and the check on an edited
// dictionary.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetDictionaryTests {

    private func profile(_ csv: String) throws -> DatasetDictionary.Profile {
        try DatasetDictionary.profile(csv: csv).get()
    }

    @Test func profilesTheHeaderAndCountsTheDataRows() throws {
        let result = try profile("id,ward,systolic\n1,A,120\n2,B,131.5\n3,A,\n")
        #expect(result.columns.map(\.name) == ["id", "ward", "systolic"])
        #expect(result.columns.map(\.valueType) == [.integer, .text, .number])
        #expect(result.rowCount == 3)
        #expect(result.columns.allSatisfy { $0.description == nil && $0.unit == nil })
    }

    @Test func aHeaderOnlyFileHasNoRowsAndTextColumns() throws {
        let result = try profile("id,ward\n")
        #expect(result.rowCount == 0)
        #expect(result.columns.map(\.valueType) == [.text, .text])
    }

    @Test(arguments: [
        (["1", "2", "-3"], DatasetColumn.ValueType.integer),
        (["1", "2.5", "1e3"], .number),
        (["true", "False", "yes"], .boolean),
        (["2024-01-02", "2024-02-03T10:15:00Z"], .date),
        (["120/80", "1"], .text),
        (["nan", "inf"], .text),
        (["", "NA", "n/a", "."], .text),
        (["7", "NA", "", "null"], .integer),
    ])
    func infersTheNarrowestTypeEveryValueFits(values: [String], expected: DatasetColumn.ValueType) {
        #expect(DatasetDictionary.inferType(of: values) == expected)
    }

    @Test func readsAQuotedCommaAsPartOfOneField() throws {
        let result = try profile("id,note,score\n1,\"tired, dizzy\",4\n")
        #expect(result.columns.map(\.valueType) == [.integer, .text, .integer])
    }

    @Test(arguments: [
        ("", DatasetDictionary.ProfileError.noHeader),
        ("id,,ward\n1,2,3\n", .blankColumnName(position: 2)),
        ("id,ward,id\n1,A,2\n", .duplicateColumn("id")),
    ])
    func refusesAFileThatIsNotAHeaderedCSV(csv: String, expected: DatasetDictionary.ProfileError) {
        #expect(throws: expected) { try DatasetDictionary.profile(csv: csv).get() }
    }

    @Test func everyProfileErrorHasAMessage() {
        let errors: [DatasetDictionary.ProfileError] = [
            .noHeader, .blankColumnName(position: 1), .duplicateColumn("id"),
        ]
        for error in errors { #expect(!error.description.isEmpty) }
    }

    // MARK: - Carrying prose onto a new version

    @Test func carriesProseByNameAndDropsColumnsTheNewHeaderLacks() throws {
        let previous = [
            DatasetColumn(name: "id", valueType: .integer, description: "Case number"),
            DatasetColumn(name: "bp", valueType: .number, description: "Systolic pressure", unit: "mmHg"),
            DatasetColumn(name: "ward", valueType: .text, description: "Admitting ward"),
        ]
        let inferred = try profile("ward,id,bp_systolic\nA,1,120\n").columns
        let carried = DatasetDictionary.carried(from: previous, onto: inferred)
        #expect(carried.columns.map(\.name) == ["ward", "id", "bp_systolic"])
        #expect(carried.columns[0].description == "Admitting ward")
        #expect(carried.columns[1].description == "Case number")
        #expect(carried.columns[2].description == nil)
        #expect(carried.droppedColumns == ["bp"])
    }

    @Test func theNewVersionsTypeWins() throws {
        let previous = [DatasetColumn(name: "bp", valueType: .integer, unit: "mmHg")]
        let inferred = try profile("bp\n120.5\n").columns
        let carried = DatasetDictionary.carried(from: previous, onto: inferred)
        #expect(carried.columns == [DatasetColumn(name: "bp", valueType: .number, unit: "mmHg")])
    }

    // MARK: - Checking an edited dictionary

    @Test func anEditNamingOnlyHeaderColumnsPasses() {
        let entries = [DatasetColumn(name: "bp", valueType: .number, unit: "mmHg")]
        #expect(DatasetDictionary.editIssue(entries, header: ["id", "bp"]) == nil)
    }

    @Test func anEditNamingAMissingColumnIsRefused() {
        let entries = [DatasetColumn(name: "pulse", valueType: .integer)]
        #expect(DatasetDictionary.editIssue(entries, header: ["id", "bp"]) != nil)
    }

    @Test func anEditNamingAColumnTwiceIsRefused() {
        let entries = [
            DatasetColumn(name: "bp", valueType: .number), DatasetColumn(name: "bp", valueType: .number),
        ]
        #expect(DatasetDictionary.editIssue(entries, header: ["bp"]) != nil)
    }
}
