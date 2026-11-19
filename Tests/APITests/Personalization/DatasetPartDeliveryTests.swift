// Tests/APITests/Personalization/DatasetPartDeliveryTests.swift
//
// `writeDatasetFiles` with a partition (docs/dataset-shared-delivery.md, step
// 2): each student's copy is a link to their stored part, two students dealt
// different parts link to different files, and the linked bytes are what
// grading resolves for that student's deal. A real file from before the
// change becomes the link.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct DatasetPartDeliveryTests {

    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"datasets":[{"file":"cases.csv","kind":"partition","partCount":2}]}
        """

    private static let pool = "id,ward\n1,A\n2,B\n3,C\n4,D\n"

    private func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    @Test func eachStudentLinksToTheirOwnPart() async throws {
        try await withTestApp(prefix: "chickadee-dsparts") { app in
            let course = try await makeTestCourse(on: app, code: "DS103")
            let courseID = try course.requireID()

            let setupID = "setup_ds_parts"
            let setup = APITestSetup(
                id: setupID, manifest: Self.manifest,
                zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
            try await setup.save(on: app.db)
            let assignment = APIAssignment(
                testSetupID: setupID, title: "Parts Lab", dueAt: nil, isOpen: true, courseID: courseID)
            try await assignment.save(on: app.db)
            let assignmentID = try assignment.requireID()

            let fm = FileManager.default
            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
            try Self.pool.write(toFile: sharedDir + "cases.csv", atomically: true, encoding: .utf8)
            let manifest = try #require(decodeManifest(from: Data(Self.manifest.utf8)))

            var targets: [String] = []
            for index in 0..<2 {
                let user = try await makeTestUser(on: app, username: "ds_parts_student_\(index)")
                let userID = try user.requireID()
                let studentDir = app.testSetupsDirectory + "student-ds-parts-\(index)"
                try fm.createDirectory(atPath: studentDir, withIntermediateDirectories: true)
                // A working copy written before part delivery: a real file.
                try "OLD".write(toFile: studentDir + "/cases.csv", atomically: true, encoding: .utf8)

                await writeDatasetFiles(
                    setup: setup, userID: userID, studentDir: studentDir, on: app.db, application: app)

                let path = studentDir + "/cases.csv"
                let target = try #require(linkTarget(path), "the student's copy is a link")
                #expect(target.hasPrefix(DatasetPartStore.root(testSetupsDirectory: app.testSetupsDirectory)))
                targets.append(target)

                let seedHex = try await AssignmentSeedStore.ensureSeed(
                    userID: userID, assignmentID: assignmentID, on: app.db)
                let deal = try await DatasetDeals.dealNumber(
                    manifest: manifest, courseID: courseID, assignmentID: assignmentID, userID: userID, on: app.db)
                let graded = DatasetResolver.resolve(
                    manifest: manifest, seedHex: seedHex, courseSeedHex: nil, dealNumber: deal,
                    sourceDirectory: sharedDir)?["cases.csv"]
                #expect(try String(contentsOfFile: path, encoding: .utf8) == graded)
            }

            #expect(targets[0] != targets[1], "two students dealt in turn hold different parts")
            #expect(try String(contentsOfFile: sharedDir + "cases.csv", encoding: .utf8) == Self.pool)
        }
    }
}
