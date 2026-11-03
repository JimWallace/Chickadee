// Tests/APITests/Personalization/DatasetWriteFailureTests.swift
//
// Pins #2776: `writeDatasetFiles` must not cache its fingerprint after a
// failed write. It used to `try?` each write and then report success, so the
// next visit skipped the rewrite and the student kept a stale dataset until
// the server restarted.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct DatasetWriteFailureTests {

    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"datasets":[{"file":"pool.csv","sampleSize":2}]}
        """

    @Test func failedWriteIsRetriedOnTheNextVisit() async throws {
        try await withTestApp(prefix: "chickadee-dsfail") { app in
            let course = try await makeTestCourse(on: app, code: "DS102")
            let courseID = try course.requireID()
            let user = try await makeTestUser(on: app, username: "ds_fail_student")
            let userID = try user.requireID()

            let setupID = "setup_ds_write_fail"
            let setup = APITestSetup(
                id: setupID, manifest: Self.manifest,
                zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
            try await setup.save(on: app.db)
            try await APIAssignment(
                testSetupID: setupID, title: "Dataset Lab", dueAt: nil, isOpen: true,
                courseID: courseID
            ).save(on: app.db)

            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
            try "id,v\n1,a\n2,b\n3,c\n4,d\n".write(
                toFile: sharedDir + "pool.csv", atomically: true, encoding: .utf8)

            let studentDir = app.testSetupsDirectory + "student-ds-fail"
            let targetPath = studentDir + "/pool.csv"
            // A non-empty directory at the target path: it counts as present,
            // and the atomic write cannot replace it.
            try FileManager.default.createDirectory(atPath: targetPath, withIntermediateDirectories: true)
            try "x".write(toFile: targetPath + "/blocker", atomically: true, encoding: .utf8)

            func visit() async {
                await writeDatasetFiles(
                    setup: setup, userID: userID, studentDir: studentDir, on: app.db, application: app)
            }

            await visit()
            let targetType = try FileManager.default.attributesOfItem(atPath: targetPath)[.type] as? FileAttributeType
            #expect(targetType == .typeDirectory, "The blocker must have made the write fail")

            // Clear the cause, and leave a stale file in its place. A cached
            // fingerprint would skip the rewrite and keep the stale bytes.
            try FileManager.default.removeItem(atPath: targetPath)
            try "STALE".write(toFile: targetPath, atomically: true, encoding: .utf8)
            await visit()
            let contents = try String(contentsOfFile: targetPath, encoding: .utf8)
            #expect(contents != "STALE", "A failed write must not be cached as current")
        }
    }
}
