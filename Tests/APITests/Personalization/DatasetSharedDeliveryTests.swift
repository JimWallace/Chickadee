// Tests/APITests/Personalization/DatasetSharedDeliveryTests.swift
//
// `writeDatasetFiles` with shared delivery (docs/dataset-shared-delivery.md):
// a dataset every student receives whole is a link to the setup's shared
// extraction, a real file from before the change becomes that link on the next
// visit, a sampled dataset beside it stays a real file of the student's own,
// and a shared source the extraction does not hold yet is not linked.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct DatasetSharedDeliveryTests {

    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"datasets":[{"file":"whole.csv"},{"file":"sample.csv","sampleSize":2},{"file":"absent.csv"}]}
        """

    private static let pool = "id,v\n1,a\n2,b\n3,c\n4,d\n"

    private func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    @Test func wholeFileIsLinkedAndSampleStaysAFile() async throws {
        try await withTestApp(prefix: "chickadee-dsshared") { app in
            let course = try await makeTestCourse(on: app, code: "DS102")
            let courseID = try course.requireID()
            let user = try await makeTestUser(on: app, username: "ds_shared_student")
            let userID = try user.requireID()

            let setupID = "setup_ds_shared"
            let setup = APITestSetup(
                id: setupID, manifest: Self.manifest,
                zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
            try await setup.save(on: app.db)
            try await APIAssignment(
                testSetupID: setupID, title: "Shared Lab", dueAt: nil, isOpen: true, courseID: courseID
            ).save(on: app.db)

            let fm = FileManager.default
            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
            try Self.pool.write(toFile: sharedDir + "whole.csv", atomically: true, encoding: .utf8)
            try Self.pool.write(toFile: sharedDir + "sample.csv", atomically: true, encoding: .utf8)

            let studentDir = app.testSetupsDirectory + "student-ds-shared"
            try fm.createDirectory(atPath: studentDir, withIntermediateDirectories: true)
            // A working copy written before shared delivery: a real file.
            try Self.pool.write(toFile: studentDir + "/whole.csv", atomically: true, encoding: .utf8)

            await writeDatasetFiles(
                setup: setup, userID: userID, studentDir: studentDir, on: app.db, application: app)

            #expect(linkTarget(studentDir + "/whole.csv") == sharedDir + "whole.csv")
            #expect(try String(contentsOfFile: studentDir + "/whole.csv", encoding: .utf8) == Self.pool)

            #expect(linkTarget(studentDir + "/sample.csv") == nil)
            let sample = try String(contentsOfFile: studentDir + "/sample.csv", encoding: .utf8)
            #expect(sample.split(separator: "\n").count == 3, "header plus two sampled rows")

            #expect(!fm.fileExists(atPath: studentDir + "/absent.csv"))
            #expect(linkTarget(studentDir + "/absent.csv") == nil, "a missing source is not linked")

            // The shared extraction keeps its bytes through the per-student write.
            #expect(try String(contentsOfFile: sharedDir + "sample.csv", encoding: .utf8) == Self.pool)
        }
    }
}
