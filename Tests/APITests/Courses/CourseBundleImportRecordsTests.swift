// Tests/APITests/Courses/CourseBundleImportRecordsTests.swift
//
// Integration tests for the records a course bundle import creates:
//
//   POST /admin/courses/import  — accept an uploaded bundle ZIP (admin only)
//
// Closes #70.
//
// Split out of the former CourseBundleTests.swift; the shared fixtures are in
// CourseBundleRouteFixtures.swift.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleImportRecordsTests: CourseBundleRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtest-imprec")
    }

    // MARK: - POST /admin/courses/import — DB record creation

    @Test func importCreatesExpectedDBRecords() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let zipData = try await makeMinimalBundleZip(courseCode: "IMP_RECORDS")

            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")
            #expect(status != .conflict)
            #expect(status != .forbidden)

            guard
                let course = try await APICourse.query(on: app.db)
                    .filter(\.$code == "IMP_RECORDS").first()
            else {
                Issue.record("Imported course should exist in DB")
                return
            }
            let courseID = try course.requireID()
            let setups = try await APITestSetup.query(on: app.db)
                .filter(\.$courseID == courseID).all()
            #expect(setups.count == 1, "Expected 1 imported test setup")

            let assignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == courseID).all()
            #expect(assignments.count == 1, "Expected 1 imported assignment")
            #expect(assignments.first?.title == "Lab 1")
            #expect(assignments.first?.isOpen == false)  // bundle sets isOpen: false

        }
    }

    /// A course bundle must carry the instructor's reference SOLUTION, and the
    /// imported assignment must end up pointing at its own copy.
    ///
    /// The solution lives in a `validation`-kind submission, not in the setup
    /// zip. Export used to collect `student` rows only, so the answer key never
    /// entered the bundle — and an imported assignment landed "pending
    /// validation" with nothing to validate against, permanently. This is the
    /// round trip that proves it travels.
    @Test func bundleRoundTripCarriesTheReferenceSolution() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "SOLN_RT")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_soln_rt", courseID: courseID)
            let setupID = try setup.requireID()
            let assignment = try await insertAssignment(testSetupID: setupID, courseID: courseID)

            let author = try await makeTestUser(on: app, username: "soln_author", role: "admin")
            let solution = try await makeTestSubmission(
                on: app, id: "sub_soln_rt", setupID: setupID,
                userID: try author.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            assignment.validationSubmissionID = try solution.requireID()
            try await assignment.save(on: app.db)
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: solution.zipPath))

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                }
            )

            // Archive the source so the import lands a second course rather
            // than being refused as an active duplicate.
            course.isArchived = true
            try await course.save(on: app.db)

            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")
            #expect(status != .conflict)
            #expect(status != .forbidden)

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "SOLN_RT")
                    .filter(\.$isArchived == false)
                    .first(),
                "the import should have created a live second course")
            let importedID = try imported.requireID()

            let importedAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == importedID).all()
            #expect(importedAssignments.count == 1)
            let importedAssignment = try #require(importedAssignments.first)

            // The solution arrived as a validation submission on the NEW setup.
            let importedSolutionID = try #require(
                importedAssignment.validationSubmissionID,
                "the imported assignment should point at its own solution")
            let importedSolution = try #require(
                try await APISubmission.find(importedSolutionID, on: app.db))
            #expect(importedSolution.kind == APISubmission.Kind.validation)
            #expect(importedSolution.testSetupID == importedAssignment.testSetupID)
            #expect(importedSolution.id != solution.id)

            // Its bytes survived the round trip.
            #expect(FileManager.default.fileExists(atPath: importedSolution.zipPath))
            let importedBytes = try Data(
                contentsOf: URL(fileURLWithPath: importedSolution.zipPath))
            #expect(importedBytes == originalBytes)
        }
    }

    /// The import writes each carried solution's source into the shared
    /// directory it built from the zip alone (#1742).
    @Test func importWritesTheSolutionSource() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "SOLN_SRC")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_soln_src", courseID: courseID)
            let setupID = try setup.requireID()
            let assignment = try await insertAssignment(testSetupID: setupID, courseID: courseID)
            let author = try await makeTestUser(on: app, username: "soln_src_author", role: "admin")
            let solution = try await makeTestSubmission(
                on: app, id: "sub_soln_src", setupID: setupID,
                userID: try author.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            try #"""
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":["def answer():\n","    return 42\n"]}]}
            """#.write(toFile: solution.zipPath, atomically: true, encoding: .utf8)
            assignment.validationSubmissionID = try solution.requireID()
            try await assignment.save(on: app.db)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "SOLN_SRC")
                    .filter(\.$isArchived == false)
                    .first())
            let importedAssignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let path = app.testSetupsDirectory + "shared/\(importedAssignment.testSetupID)/solution.py"
            let written = try String(contentsOfFile: path, encoding: .utf8)
            #expect(written.contains("def answer"))
        }
    }

    /// The starter notebook lives beside the zip and is edited in place, so
    /// the bundle carries the flat file as it is now, not the zip entry
    /// (#1736).
    @Test func roundTripCarriesTheEditedStarterNotebook() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "NB_RT")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_nb_rt", courseID: courseID)
            _ = try await insertAssignment(testSetupID: try setup.requireID(), courseID: courseID)
            let edited =
                #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":["Edited after publish\n"]}]}"#
            let notebookPath = app.testSetupsDirectory + "setup_nb_rt.ipynb"
            try edited.write(toFile: notebookPath, atomically: true, encoding: .utf8)
            setup.notebookPath = notebookPath
            try await setup.save(on: app.db)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "NB_RT")
                    .filter(\.$isArchived == false)
                    .first())
            let importedSetup = try #require(
                try await APITestSetup.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let importedNotebookPath = try #require(importedSetup.notebookPath)
            #expect(try String(contentsOfFile: importedNotebookPath, encoding: .utf8) == edited)
        }
    }

    /// An imported assignment starts with a `v1` whose origin says it
    /// arrived by import (#1741), as a clone or a creation does.
    @Test func importSeedsAnInitialVersion() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "VERS_RT")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_vers_rt", courseID: courseID)
            _ = try await insertAssignment(testSetupID: try setup.requireID(), courseID: courseID)
            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in zipData = Data(res.body.readableBytesView) }
            )
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "VERS_RT")
                    .filter(\.$isArchived == false)
                    .first())
            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let versions = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == assignment.testSetupID)
                .all()
            #expect(versions.count == 1)
            #expect(versions.first?.origin == AssignmentVersionOrigin.bundleImport)
        }
    }

    /// Import keeps each submission's `submittedAt` and each result's
    /// `receivedAt` from the bundle (#1739), not the import time.
    @Test func bundleRoundTripCarriesTimestamps() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "TIME_RT")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_time_rt", courseID: courseID)
            let setupID = try setup.requireID()
            _ = try await insertAssignment(testSetupID: setupID, courseID: courseID)
            let student = try await makeTestUser(on: app, username: "time_student", role: "student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
            let submittedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let receivedAt = Date(timeIntervalSince1970: 1_700_000_060)
            let submission = try await makeTestSubmission(
                on: app, id: "sub_time_rt", setupID: setupID, userID: try student.requireID(),
                filename: "warmup.py")
            submission.submittedAt = submittedAt
            try await submission.save(on: app.db)
            let result = try await makeTestResult(on: app, submissionID: "sub_time_rt")
            result.receivedAt = receivedAt
            try await result.save(on: app.db)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                }
            )
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "TIME_RT")
                    .filter(\.$isArchived == false)
                    .first())
            let importedAssignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let importedSubmission = try #require(
                try await APISubmission.query(on: app.db)
                    .filter(\.$testSetupID == importedAssignment.testSetupID)
                    .filter(\.$kind == APISubmission.Kind.student)
                    .first())
            let importedSubmittedAt = try #require(importedSubmission.submittedAt)
            #expect(abs(importedSubmittedAt.timeIntervalSince(submittedAt)) < 1)
            let importedResult = try #require(
                try await APIResult.query(on: app.db)
                    .filter(\.$submissionID == (try importedSubmission.requireID()))
                    .first())
            let importedReceivedAt = try #require(importedResult.receivedAt)
            #expect(abs(importedReceivedAt.timeIntervalSince(receivedAt)) < 1)
        }
    }

    /// A bundle exported by an older build carries no language declaration.
    /// Import must supply one, because import is otherwise a permanent source of
    /// undeclared assignments — and "undeclared" is precisely the state the
    /// worker has to be able to refuse rather than guess at. A refusal that
    /// legitimate imports can trip is one that has to be watered down.
    @Test func importDeclaresALanguageForAnUndeclaredBundle() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let zipData = try await makeMinimalBundleZip(courseCode: "IMP_LANG")

            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "IMP_LANG").first())
            let setup = try #require(
                try await APITestSetup.query(on: app.db)
                    .filter(\.$courseID == course.requireID()).first())
            let manifest = try #require(setup.decodedManifest())

            #expect(
                manifest.languageDeclared == true,
                "an imported setup must carry a declaration, whatever the bundle said")
            // The fixture's suite is `.sh`, so the truthful declaration is "no
            // language" — recorded as the flag with no `language` beside it,
            // which is exactly what distinguishes it from never having asked.
            #expect(manifest.language == nil)
        }
    }

    @Test func importMatchesExistingUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            // Pre-create the user that the bundle will reference
            let hash = try testPasswordHash("existing-pw")
            let existingUser = APIUser(username: "cb_existing_student", passwordHash: hash, role: "student")
            try await existingUser.save(on: app.db)
            let existingID = try existingUser.requireID()
            let userCountBefore = try await APIUser.query(on: app.db).count()

            let zipData = try await makeBundleZipWithUser(
                courseCode: "USERMATCH_CB",
                username: "cb_existing_student"
            )
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .forbidden, "\(body)")
            #expect(status != .badRequest, "\(body)")

            // No new user should have been created
            let userCountAfter = try await APIUser.query(on: app.db).count()
            #expect(userCountAfter == userCountBefore, "No new user should be created when username already exists")

            // The enrollment should reference the pre-existing user
            let course = try await APICourse.query(on: app.db)
                .filter(\.$code == "USERMATCH_CB").first()
            #expect(course != nil)
            guard let courseID2 = try course?.requireID() else {
                Issue.record("Imported course USERMATCH_CB not found in DB")
                return
            }
            let enrollment = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID2).first()
            #expect(enrollment?.userID == existingID, "Enrollment should point to the pre-existing user")

        }
    }

    @Test func importCreatesPlaceholderUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            let zipData = try await makeBundleZipWithUser(
                courseCode: "PLACEHOLDER_CB",
                username: "cb_brand_new_user"
            )
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .forbidden, "\(body)")
            #expect(status != .badRequest, "\(body)")

            let placeholder = try await APIUser.query(on: app.db)
                .filter(\.$username == "cb_brand_new_user").first()
            #expect(placeholder != nil, "Placeholder user should be created")
            #expect(
                placeholder?.passwordHash.isEmpty == true,
                "Placeholder user should have empty passwordHash (inert account)"
            )

        }
    }
}
