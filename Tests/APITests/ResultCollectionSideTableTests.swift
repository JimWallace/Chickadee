// Tests/APITests/ResultCollectionSideTableTests.swift
//
// #1173: results.collection_json moves to the result_collections side table.
// Pins the three load-bearing pieces: the migration's chunked backfill (every
// pre-existing blob copied, column dropped, multiple chunk passes proven on a
// multi-thousand-row table), the transactional write path (row + blob
// persist together and cascade-delete together), and the batch blob loader.

import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ResultCollectionSideTableTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-rescol")
    }

    private func seedSubmission(id: String) async throws {
        let setupID = "setup_rescol"
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            let courseID = try await app.testCourseID()
            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: app.testSetupsDirectory + "\(setupID).zip",
                courseID: courseID
            )
            try await setup.save(on: app.db)
        }
        let sub = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1,
            status: SubmissionStatus.complete.rawValue
        )
        try await sub.save(on: app.db)
    }

    @Test func saveWithCollectionPersistsRowAndBlobTogether() async throws {
        try await withApp(app) { _ in
            try await seedSubmission(id: "sub_rc_write")
            let json = #"{"earnedPoints":3,"totalPoints":4,"passCount":3,"totalTests":4}"#

            let result = APIResult(id: "res_rc_write", submissionID: "sub_rc_write")
            try await result.saveWithCollection(json: json, on: app.db)

            // Blob row exists and round-trips byte-identically.
            let loaded = try await result.loadCollectionJSON(on: app.db)
            #expect(loaded == json)

            // Grade columns were stamped from the blob on the way in.
            let row = try #require(try await APIResult.find("res_rc_write", on: app.db))
            #expect(row.earnedPoints == 3)
            #expect(row.totalPoints == 4)
            #expect(row.passCount == 3)
            #expect(row.totalTests == 4)
        }
    }

    @Test func deletingTheResultCascadesTheBlob() async throws {
        try await withApp(app) { _ in
            try await seedSubmission(id: "sub_rc_cascade")
            let result = APIResult(id: "res_rc_cascade", submissionID: "sub_rc_cascade")
            try await result.saveWithCollection(json: "{}", on: app.db)
            #expect(try await APIResultCollection.find("res_rc_cascade", on: app.db) != nil)

            try await result.delete(on: app.db)
            #expect(try await APIResultCollection.find("res_rc_cascade", on: app.db) == nil)
        }
    }

    @Test func batchLoaderReturnsBlobsKeyedByResultID() async throws {
        try await withApp(app) { _ in
            try await seedSubmission(id: "sub_rc_batch")
            try await APIResult(id: "res_rc_b1", submissionID: "sub_rc_batch")
                .saveWithCollection(json: #"{"passCount":1,"totalTests":2}"#, on: app.db)
            try await APIResult(id: "res_rc_b2", submissionID: "sub_rc_batch")
                .saveWithCollection(json: #"{"passCount":2,"totalTests":2}"#, on: app.db)

            let byID = try await collectionJSONByResultID(
                for: ["res_rc_b1", "res_rc_b2", "res_rc_missing"], on: app.db)
            #expect(byID.count == 2)
            #expect(byID["res_rc_b1"]?.contains(#""passCount":1"#) == true)
            #expect(byID["res_rc_b2"]?.contains(#""passCount":2"#) == true)
            #expect(byID["res_rc_missing"] == nil)
        }
    }
}

/// The migration itself, run against a legacy-shaped schema seeded with more
/// rows than one backfill chunk — proving the chunked copy visits everything
/// and the column drop lands. Uses a bare Application (not makeTestApp) so
/// the schema can be created pre-migration.
@Suite(.serialized) struct ResultCollectionBackfillMigrationTests {

    @Test func chunkedBackfillCopiesEveryBlobAndDropsTheColumn() async throws {
        let app = try await Application.make(.testing)
        do {
            try configureDatabase(app, settings: .sqliteInMemory())
            let sql = try #require(app.db as? SQLDatabase)

            // Legacy shape: minimal parents + a results table that still
            // carries collection_json. Only the columns the migration touches
            // are needed.
            try await sql.raw("CREATE TABLE submissions (id TEXT PRIMARY KEY)").run()
            try await sql.raw(
                """
                CREATE TABLE results (
                    id TEXT PRIMARY KEY,
                    submission_id TEXT NOT NULL REFERENCES submissions(id),
                    collection_json TEXT NOT NULL,
                    source TEXT
                )
                """
            ).run()
            try await sql.raw("INSERT INTO submissions (id) VALUES ('sub_bf')").run()

            // 2,500 rows: three passes at the 1,000-row chunk size.
            let totalRows = 2_500
            let batchSize = 500
            var rowID = 1
            while rowID <= totalRows {
                let values = (rowID..<min(rowID + batchSize, totalRows + 1))
                    .map { i in
                        #"('res_bf_\#(i)', 'sub_bf', '{"passCount":\#(i),"totalTests":\#(totalRows)}', 'worker')"#
                    }
                    .joined(separator: ",")
                try await sql.raw(
                    "INSERT INTO results (id, submission_id, collection_json, source) VALUES \(unsafeRaw: values)"
                ).run()
                rowID += batchSize
            }

            app.migrations.add(CreateResultCollections())
            try await app.autoMigrate()

            // Every blob copied, byte-identical.
            let copied = try await APIResultCollection.query(on: app.db).count()
            #expect(copied == totalRows)
            let first = try await APIResultCollection.find("res_bf_1", on: app.db)
            #expect(first?.collectionJSON == #"{"passCount":1,"totalTests":2500}"#)
            let last = try await APIResultCollection.find("res_bf_2500", on: app.db)
            #expect(last?.collectionJSON == #"{"passCount":2500,"totalTests":2500}"#)

            // The column is gone from the hot table.
            struct AnyRow: Decodable {}
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT collection_json FROM results LIMIT 1")
                    .first(decoding: AnyRow.self)
            }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
