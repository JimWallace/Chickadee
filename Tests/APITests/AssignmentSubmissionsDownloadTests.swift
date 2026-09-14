// Tests/APITests/AssignmentSubmissionsDownloadTests.swift
//
// GET /instructor/:assignmentID/submissions.zip — every enrolled student's
// LATEST submission, one directory per student plus an index, streamed as a
// zip; a redirect with an error banner when there is nothing to download.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized)
struct AssignmentSubmissionsDownloadTests {

    @Test func zipsEachStudentsLatestSubmissionWithAnIndex() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let alice = try await arInsertStudent(username: "dl_alice", on: app)
            try await arEnrollStudentInTestCourse(alice, on: app)
            let bob = try await arInsertStudent(username: "dl_bob", on: app)
            try await arEnrollStudentInTestCourse(bob, on: app)
            // Carol is enrolled but never submits: no directory for her.
            let carol = try await arInsertStudent(username: "dl_carol", on: app)
            try await arEnrollStudentInTestCourse(carol, on: app)

            try await arInsertSetup(id: "dl_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "dl_setup", title: "Download Lab", isOpen: true, on: app)

            // Alice: two attempts; only the newer one ships.
            for attempt in 1...2 {
                let sub = try await arInsertSubmission(
                    id: "sub_dl_a\(attempt)", testSetupID: "dl_setup",
                    userID: alice.requireID(), attemptNumber: attempt, on: app)
                sub.filename = "warmup.py"
                try await sub.save(on: app.db)
                try "print(\(attempt))".write(
                    to: URL(fileURLWithPath: sub.zipPath), atomically: true, encoding: .utf8)
            }
            let bobSub = try await arInsertSubmission(
                id: "sub_dl_b1", testSetupID: "dl_setup",
                userID: bob.requireID(), attemptNumber: 1, on: app)
            try "print('bob')".write(
                to: URL(fileURLWithPath: bobSub.zipPath), atomically: true, encoding: .utf8)

            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dl-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions.zip",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .contentType) == "application/zip")
                    #expect(
                        res.headers.first(name: .contentDisposition)?
                            .contains("chickadee-submissions-") == true)
                    zipData = Data(res.body.readableBytesView)
                })

            let zipPath = extractDir.appendingPathExtension("zip").path
            defer { try? FileManager.default.removeItem(atPath: zipPath) }
            try zipData.write(to: URL(fileURLWithPath: zipPath))
            try await extractZipArchive(zipPath: zipPath, into: extractDir)

            let aliceFile = extractDir.appendingPathComponent("dl_alice/warmup.py")
            #expect(
                try String(contentsOf: aliceFile, encoding: .utf8) == "print(2)",
                "the newer attempt is the one shipped")
            let bobFile = extractDir.appendingPathComponent("dl_bob/sub_dl_b1.zip")
            #expect(FileManager.default.fileExists(atPath: bobFile.path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: extractDir.appendingPathComponent("dl_carol").path),
                "a student with no submission gets no directory")

            let index = try String(
                contentsOf: extractDir.appendingPathComponent("index.csv"), encoding: .utf8)
            let lines = index.split(separator: "\n").map(String.init)
            #expect(lines.first == "username,submission_id,attempt,submitted_at,path")
            #expect(lines.count == 3)
            #expect(lines[1].hasPrefix("dl_alice,sub_dl_a2,2,"))
            #expect(lines[1].hasSuffix(",dl_alice/warmup.py"))
            #expect(lines[2].hasPrefix("dl_bob,sub_dl_b1,1,"))
        }
    }

    @Test func redirectsWithAnErrorWhenNothingHasBeenSubmitted() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "dl_empty", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "dl_empty", title: "Empty Lab", isOpen: true, on: app)
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions.zip",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })
            // The page renders the banner it was redirected to.
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions?error=No+submissions+to+download",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("No submissions to download"))
                })
        }
    }
}
