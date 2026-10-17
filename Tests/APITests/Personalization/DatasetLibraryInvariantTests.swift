// Tests/APITests/DatasetLibraryInvariantTests.swift
//
// The doors that defend "a spec with a library source names the file's own
// bytes" (docs/datasets-course-library.md, slice 3), and the rules that keep
// a sample from silently becoming the whole file: the test-setup upload
// refuses a source that does not match, a version restore drops a source
// whose dataset is gone, `set_dataset` keeps a stored sample it is not given,
// and an attach refuses a stratum with no sample.

import Core
import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class DatasetLibraryInvariantTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-invariant")
    }

    private var directory: String { app.testSetupsDirectory }
    private var blobs: AssignmentVersionBlobStore { AssignmentVersionBlobStore(testSetupsDirectory: directory) }
    private let casesCSV = "id,ward\n1,A\n2,B\n3,A\n4,B\n"

    private func dataset(courseID: UUID) async throws -> APICourseDataset {
        try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(name: "Cases", slug: "cases", description: nil, provenance: nil, licence: nil),
            upload: .init(filename: "cases.csv", bytes: Data(casesCSV.utf8), note: nil), blobs: blobs, on: app.db
        ).dataset
    }

    // MARK: - The test-setup upload

    private struct UploadFixture {
        let courseID: UUID
        let cookie: String
        let csrf: String
    }

    private func uploadFixture() async throws -> UploadFixture {
        let course = APICourse(code: "DSINV", name: "Invariant", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let cookie = try await loginUser(username: "dsinv_inst", password: "pw", role: "instructor", on: app)
        try await promoteToInstructor("dsinv_inst", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return UploadFixture(courseID: try course.requireID(), cookie: sessionCookie, csrf: csrf)
    }

    /// Posts a worker-graded setup whose zip holds a test and `cases.csv` with
    /// `csv`, and whose manifest attaches `cases.csv` from library version 1.
    private func upload(_ fx: UploadFixture, csv: String) async throws -> (HTTPStatus, String) {
        let zipPath = directory + "upload-\(UUID().uuidString).zip"
        try await writeZipFixture(at: zipPath, entries: [("test_a.sh", "exit 0\n"), ("cases.csv", csv)])
        let zip = try Data(contentsOf: URL(fileURLWithPath: zipPath))
        try? FileManager.default.removeItem(atPath: zipPath)

        let manifest =
            #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"#
            + #""testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10,"makefile":null,"#
            + #""datasets":[{"file":"cases.csv","source":{"slug":"cases","version":1},"transforms":[]}]}"#
        let boundary = "DSInvariant"
        var body = ByteBufferAllocator().buffer(capacity: zip.count + 1024)
        for (name, value) in [("_csrf", fx.csrf), ("manifest", manifest), ("courseID", fx.courseID.uuidString)] {
            body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        body.writeString(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"setup.zip\"\r\n"
                + "Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zip)
        body.writeString("\r\n--\(boundary)--\r\n")

        var result: (HTTPStatus, String) = (.imATeapot, "")
        try await app.asyncTest(
            .POST, "/api/v1/testsetups",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = .init(buffer: body)
            },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    @Test func theUploadRefusesASourceThisCourseDoesNotHave() async throws {
        try await withApp(app) { app in
            let fx = try await uploadFixture()
            let (status, body) = try await upload(fx, csv: casesCSV)
            #expect(status == .unprocessableEntity)
            #expect(body.contains("does not have"))
            #expect(try await APITestSetup.query(on: app.db).filter(\.$courseID == fx.courseID).count() == 0)
        }
    }

    @Test func theUploadRefusesAFileThatIsNotTheVersion() async throws {
        try await withApp(app) { _ in
            let fx = try await uploadFixture()
            _ = try await dataset(courseID: fx.courseID)
            let (status, body) = try await upload(fx, csv: "id,ward\n9,Z\n")
            #expect(status == .unprocessableEntity)
            #expect(body.contains("not the same file"))
        }
    }

    @Test func theUploadAcceptsAMatchingSource() async throws {
        try await withApp(app) { app in
            let fx = try await uploadFixture()
            _ = try await dataset(courseID: fx.courseID)
            let (status, body) = try await upload(fx, csv: casesCSV)
            #expect(status.code < 300, "\(status): \(body)")
            let setup = try #require(
                try await APITestSetup.query(on: app.db).filter(\.$courseID == fx.courseID).first())
            #expect(setup.decodedManifest()?.datasets.first?.source == DatasetSource(slug: "cases", version: 1))
        }
    }

    // MARK: - Version restore

    @Test func aRestoreDropsTheSourceOfADeletedDataset() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "DSINVR", name: "Restore").requireID()
            let user = try await makeTestUser(on: app, username: "dsinv_restore", role: "instructor")
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: courseID)
            let setupID = "dsinv_restore_setup"
            try await makeTestSetup(
                on: app, id: setupID, courseID: courseID,
                manifest:
                    #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}"#,
                withNotebook: false, withZip: false)
            try await writeZipFixture(at: directory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: setupID, courseID: courseID, title: "Restore lab")

            let library = try await dataset(courseID: courseID)
            var setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            try await CourseDatasetService.attach(
                library, to: setup,
                request: .init(version: 1, filename: nil, sampleSize: 2, stratumColumn: nil, scope: .assignment),
                testSetupsDirectory: directory, on: app.db)
            setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            _ = try await AssignmentVersionStore.record(
                setup: setup, request: AssignmentVersionRequest(origin: "test:attached"),
                testSetupsDirectory: directory, on: app.db)

            try await CourseDatasetService.detach(
                file: "cases.csv", from: setup, removeFile: false, testSetupsDirectory: directory, on: app.db)
            try await CourseDatasetService.delete(library, on: app.db)
            setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            _ = try await AssignmentVersionStore.record(
                setup: setup, request: AssignmentVersionRequest(origin: "test:detached"),
                testSetupsDirectory: directory, on: app.db)

            let versions = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == setupID).sort(\.$versionNumber).all()
            let attachedVersion = try #require(
                versions.first { decodeManifest(fromJSON: $0.manifest)?.datasets.first?.source != nil })
            _ = try await RestoreAssignmentVersionTool().execute(
                RestoreAssignmentVersionTool.Input(
                    assignmentPublicID: assignment.publicID, version: attachedVersion.versionNumber),
                ToolContext(
                    request: makeTestRequest(on: app), subject: "dsinv_restore", grantedScopes: [.read, .write]))

            let restored = try #require(try await APITestSetup.find(setupID, on: app.db))
            #expect(restored.decodedManifest()?.datasets == [DatasetSpec(file: "cases.csv", sampleSize: 2)])
        }
    }

    // MARK: - Keeping a sample

    @Test func setDatasetKeepsAStoredSampleItIsNotGiven() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "DSINVS", name: "Sample").requireID()
            let user = try await makeTestUser(on: app, username: "dsinv_sample", role: "instructor")
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: courseID)
            let setupID = "dsinv_sample_setup"
            try await makeTestSetup(
                on: app, id: setupID, courseID: courseID,
                manifest:
                    #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}"#,
                withNotebook: false, withZip: false)
            try await writeZipFixture(at: directory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: setupID, courseID: courseID, title: "Sample lab")
            let library = try await dataset(courseID: courseID)
            try await CourseDatasetService.attach(
                library, to: try #require(try await APITestSetup.find(setupID, on: app.db)),
                request: .init(version: 1, filename: nil, sampleSize: 3, stratumColumn: nil, scope: .assignment),
                testSetupsDirectory: directory, on: app.db)

            _ = try await SetDatasetTool().execute(
                SetDatasetTool.Input(
                    assignmentPublicID: assignment.publicID, filename: "cases.csv", sampleSize: nil,
                    stratumColumn: "ward", remove: nil, transforms: nil),
                ToolContext(request: makeTestRequest(on: app), subject: "dsinv_sample", grantedScopes: [.read, .write]))

            let spec = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.decodedManifest()?.datasets.first)
            #expect(spec.sampleSize == 3)
            #expect(spec.kind == .stratifiedSample)
            #expect(spec.source == DatasetSource(slug: "cases", version: 1))
        }
    }

    @Test func anAttachRefusesAStratumWithNoSample() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "DSINVT", name: "Stratum").requireID()
            let setupID = "dsinv_stratum_setup"
            try await makeTestSetup(
                on: app, id: setupID, courseID: courseID,
                manifest:
                    #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}"#,
                withNotebook: false, withZip: false)
            try await writeZipFixture(at: directory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
            let library = try await dataset(courseID: courseID)
            await #expect(throws: CourseDatasetError.self) {
                try await CourseDatasetService.attach(
                    library, to: try #require(try await APITestSetup.find(setupID, on: app.db)),
                    request: .init(
                        version: 1, filename: nil, sampleSize: nil, stratumColumn: "ward", scope: .assignment),
                    testSetupsDirectory: self.directory, on: app.db)
            }
        }
    }
}
