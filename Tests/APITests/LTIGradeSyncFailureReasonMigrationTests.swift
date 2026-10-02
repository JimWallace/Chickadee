// Tests/APITests/LTIGradeSyncFailureReasonMigrationTests.swift
//
// `AddLTIGradeSyncFailureReasonColumn` backfills the failure code on rows
// whose stored sentence says the student had not launched. That sentence
// must be the one those rows were written with, frozen in the migration,
// never the live `LTIGradeSyncSweep.notLaunchedMessage`: rewording the live
// sentence before a database applies the migration would otherwise backfill
// nothing, silently (#1811).

import Foundation
import Testing

@testable import APIServer

@Suite struct LTIGradeSyncFailureReasonMigrationTests {

    /// The frozen sentence is the one the sweep stored when the rows were
    /// written. Pinned as a literal so a rewording of the live sentence
    /// cannot move it.
    @Test func theBackfillMatchesTheSentenceTheRowsWereWrittenWith() {
        #expect(
            AddLTIGradeSyncFailureReasonColumn.storedNotLaunchedMessage
                == "The student has not opened Chickadee from the LMS yet.")
    }

    /// The migration source never reaches for the live sentence.
    @Test func theMigrationDoesNotTrackTheLiveSentence() throws {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/APIServer/Migrations/AddLTIGradeSyncFailureReasonColumn.swift"),
            encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.joined(separator: "\n").contains("LTIGradeSyncSweep.notLaunchedMessage"))
    }
}
