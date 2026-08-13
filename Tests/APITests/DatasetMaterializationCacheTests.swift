// Tests/APITests/DatasetMaterializationCacheTests.swift
//
// Pins the dataset materialization short-circuit (#1382 item 3):
// `writeDatasetFiles` used to re-slice the source and overwrite every
// dataset file on every notebook visit; now an unchanged fingerprint with
// all targets present skips the work, while each regeneration trigger the
// always-rewrite had — a changed source, a re-seed, a deleted target —
// still re-materializes.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct DatasetMaterializationCacheTests {

    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"datasets":[{"file":"pool.csv","sampleSize":2}]}
        """

    @Test func materializationSkipsWhenInputsAreUnchanged() async throws {
        let app = try await makeTestApp(prefix: "chickadee-dsc")
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "DS101")
            let courseID = try course.requireID()
            let user = try await makeTestUser(on: app, username: "ds_student")
            let userID = try user.requireID()

            let setupID = "setup_ds_cache"
            let setup = APITestSetup(
                id: setupID, manifest: Self.manifest,
                zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
            try await setup.save(on: app.db)
            try await APIAssignment(
                testSetupID: setupID, title: "Dataset Lab", dueAt: nil, isOpen: true,
                courseID: courseID
            ).save(on: app.db)

            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try FileManager.default.createDirectory(
                atPath: sharedDir, withIntermediateDirectories: true)
            let sourcePath = sharedDir + "pool.csv"
            try "id,v\n1,a\n2,b\n3,c\n4,d\n".write(
                toFile: sourcePath, atomically: true, encoding: .utf8)

            let studentDir = app.testSetupsDirectory + "student-ds-cache"
            try FileManager.default.createDirectory(
                atPath: studentDir, withIntermediateDirectories: true)
            let targetPath = studentDir + "/pool.csv"

            func visit() async {
                let req = Request(application: app, on: app.eventLoopGroup.any())
                await writeDatasetFiles(
                    req: req, setup: setup, userID: userID, studentDir: studentDir)
            }

            // First visit materializes the per-student slice.
            await visit()
            let sliced = try #require(try? String(contentsOfFile: targetPath, encoding: .utf8))
            #expect(!sliced.isEmpty)

            // Unchanged inputs: the visit must NOT rewrite the file — the
            // tamper marker surviving is the skip observably happening (the
            // old always-rewrite would restore the slice here).
            try "TAMPERED".write(toFile: targetPath, atomically: true, encoding: .utf8)
            await visit()
            #expect(
                (try? String(contentsOfFile: targetPath, encoding: .utf8)) == "TAMPERED",
                "An unchanged fingerprint with the target present must skip the rewrite")

            // A changed source (different bytes → different size) invalidates
            // the fingerprint and re-materializes.
            try "id,v\n1,a\n2,b\n3,c\n4,d\n5,e\n6,f\n".write(
                toFile: sourcePath, atomically: true, encoding: .utf8)
            await visit()
            let refreshed = try #require(try? String(contentsOfFile: targetPath, encoding: .utf8))
            #expect(refreshed != "TAMPERED", "A source edit must re-materialize the slice")

            // A deleted target is repaired even with an unchanged fingerprint.
            try FileManager.default.removeItem(atPath: targetPath)
            await visit()
            #expect(
                FileManager.default.fileExists(atPath: targetPath),
                "A deleted dataset file is repaired on the next visit")

            // A re-seed (staff action) changes the per-student seed, which
            // invalidates the fingerprint and re-slices.
            try "TAMPERED".write(toFile: targetPath, atomically: true, encoding: .utf8)
            try await APIAssignmentPersonalizationSeed.query(on: app.db).delete()
            await visit()
            let reseeded = try #require(try? String(contentsOfFile: targetPath, encoding: .utf8))
            #expect(reseeded != "TAMPERED", "A re-seed must re-materialize the slice")
        }
    }
}
