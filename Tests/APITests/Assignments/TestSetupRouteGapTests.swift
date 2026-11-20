// Tests/APITests/Assignments/TestSetupRouteGapTests.swift
//
// The refusals and the less common paths of `TestSetupRoutes`, which the
// coverage report showed unrun:
//
//   POST /api/v1/testsetups                  — bad manifest, mode rules, corrupt zip,
//                                              browser setup that stores its notebook
//   GET  /api/v1/testsetups/:id/download     — not found, student refused, staff read
//   GET  /api/v1/testsetups/:id/support/:f   — every refusal, and the served file
//   PUT  /api/v1/testsetups/:id/assignment   — empty body, non-JSON body, existing path

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
final class TestSetupRouteGapTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-setup-gaps")
    }

    // MARK: - Fixtures

    private let notebookJSON =
        #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[]}]}"#

    /// An instructor of TEST101 (an `.auto` course), with a CSRF token bound
    /// to the session.
    private func instructorSession() async throws -> (csrf: String, cookie: String, courseID: UUID) {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsCourseInstructor(username: "gaps_instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        return (csrf, sessionCookie, courseID)
    }

    /// The bytes of a zip that holds `entries`.
    private func zipBytes(_ entries: [(String, String)]) async throws -> Data {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-gaps-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await writeZipFixture(at: path, entries: entries)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Sends a multipart upload and returns the status and the body text.
    private func upload(
        manifest: String, files: Data, courseID: UUID, csrf: String, cookie: String
    ) async throws -> (HTTPStatus, String) {
        let boundary = "SetupGapsBoundary"
        var body = ByteBufferAllocator().buffer(capacity: 1024 + files.count)
        func part(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }
        part("_csrf", csrf)
        part("manifest", manifest)
        part("courseID", courseID.uuidString)
        body.writeString("--\(boundary)\r\n")
        body.writeString(
            "Content-Disposition: form-data; name=\"files\"; filename=\"setup.zip\"\r\n"
                + "Content-Type: application/zip\r\n\r\n")
        body.writeBytes(files)
        body.writeString("\r\n--\(boundary)--\r\n")

        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .POST, "/api/v1/testsetups",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = .init(buffer: body)
            },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    private func get(_ path: String, cookie: String) async throws -> (HTTPStatus, HTTPHeaders, Data) {
        var result: (HTTPStatus, HTTPHeaders, Data) = (.internalServerError, [:], Data())
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in result = (res.status, res.headers, Data(res.body.readableBytesView)) })
        return result
    }

    private func put(_ path: String, body: String, csrf: String, cookie: String) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .PUT, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                if !body.isEmpty { req.body = ByteBuffer(string: body) }
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func zipFilesInSetupsDirectory() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: app.testSetupsDirectory)
        return Set(names.filter { $0.hasSuffix(".zip") })
    }

    private let supportManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"t.sh"}],"graderOnlyFiles":["answers.csv"],"timeLimitSeconds":10,"makefile":null}"#

    /// A worker setup whose zip holds a support file, a test script, a
    /// reserved notebook name and a grader-only file, with an open
    /// assignment in TEST101.
    private func insertSupportSetup(isOpen: Bool = true) async throws -> String {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "setup_gaps_\(UUID().uuidString.lowercased().prefix(6))"
        let zipPath = app.testSetupsDirectory + "\(setupID).zip"
        try await writeZipFixture(
            at: zipPath,
            entries: [
                ("data.csv", "a,b\n1,2\n"),
                ("t.sh", "exit 0\n"),
                ("assignment.ipynb", notebookJSON),
                ("answers.csv", "secret\n"),
            ])
        try await APITestSetup(id: setupID, manifest: supportManifest, zipPath: zipPath, courseID: courseID)
            .save(on: app.db)
        try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID, isOpen: isOpen)
        return setupID
    }

    // MARK: - POST /api/v1/testsetups

    @Test func uploadRefusesAManifestThatIsNotJSON() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let (status, body) = try await upload(
                manifest: "{not json", files: Data("PK".utf8), courseID: session.courseID,
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .unprocessableEntity)
            #expect(body.contains("Invalid manifest JSON"))
        }
    }

    @Test func uploadRefusesABrowserSetupWithNoNotebook() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            let files = try await zipBytes([("data.csv", "a,b\n")])
            let (status, body) = try await upload(
                manifest: manifest, files: files, courseID: session.courseID,
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .unprocessableEntity)
            #expect(body.contains("at least one .ipynb"))
        }
    }

    @Test func uploadRefusesAWorkerSetupWithNoSuites() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            let files = try await zipBytes([("t.sh", "exit 0\n")])
            let (status, body) = try await upload(
                manifest: manifest, files: files, courseID: session.courseID,
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .unprocessableEntity)
            #expect(body.contains("at least one test suite"))
        }
    }

    /// A zip that `unzip` cannot read is refused, and its bytes do not stay
    /// on disk.
    @Test func uploadRefusesACorruptZipAndDeletesIt() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let before = try zipFilesInSetupsDirectory()
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"t.sh"}],"timeLimitSeconds":10,"makefile":null}"#
            let (status, body) = try await upload(
                manifest: manifest, files: Data("PK not a zip".utf8), courseID: session.courseID,
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .unprocessableEntity)
            #expect(body.contains("Could not read uploaded zip"))
            #expect(try zipFilesInSetupsDirectory() == before)
            #expect(try await APITestSetup.query(on: app.db).count() == 0)
        }
    }

    /// A browser setup stores a flat copy of its notebook, so the editor can
    /// open it without the zip.
    @Test func uploadOfABrowserSetupStoresItsNotebook() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            let files = try await zipBytes([("assignment.ipynb", notebookJSON), ("data.csv", "a\n")])
            let (status, body) = try await upload(
                manifest: manifest, files: files, courseID: session.courseID,
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .created, "body: \(body)")

            let decoded = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
            let setupID = try #require(decoded["testSetupID"])
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            let notebookPath = try #require(setup.notebookPath)
            #expect(notebookPath == app.testSetupsDirectory + "\(setupID).ipynb")
            let stored = try String(contentsOfFile: notebookPath, encoding: .utf8)
            #expect(stored.contains("x = 1"))
        }
    }

    // MARK: - GET /api/v1/testsetups/:id/download

    @Test func downloadOfAnUnknownSetupIsNotFound() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let (status, _, _) = try await get("/api/v1/testsetups/setup_missing/download", cookie: session.cookie)
            #expect(status == .notFound)
        }
    }

    /// The zip holds secret tests and the solution, so a student of the same
    /// course does not get it.
    @Test func downloadOfTheSetupZipRefusesAStudent() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSupportSetup()
            let cookie = try await loginAsStudent("gaps_student", on: app)
            let (status, _, _) = try await get("/api/v1/testsetups/\(setupID)/download", cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func downloadOfTheSetupZipServesTheInstructor() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = try await insertSupportSetup()
            let (status, _, bytes) = try await get("/api/v1/testsetups/\(setupID)/download", cookie: session.cookie)
            #expect(status == .ok)
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: app.testSetupsDirectory + "\(setupID).zip"))
            #expect(bytes == onDisk)
        }
    }

    // MARK: - GET /api/v1/testsetups/:id/support/:filename

    @Test func supportFileOfAnUnknownSetupIsNotFound() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let (status, _, _) = try await get(
                "/api/v1/testsetups/setup_missing/support/data.csv", cookie: session.cookie)
            #expect(status == .notFound)
        }
    }

    @Test func supportFileRefusesADotDotName() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = try await insertSupportSetup()
            let (status, _, _) = try await get(
                "/api/v1/testsetups/\(setupID)/support/..data.csv", cookie: session.cookie)
            #expect(status == .badRequest)
        }
    }

    @Test func supportFileNotInTheZipIsNotFound() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = try await insertSupportSetup()
            let (status, _, _) = try await get(
                "/api/v1/testsetups/\(setupID)/support/missing.csv", cookie: session.cookie)
            #expect(status == .notFound)
        }
    }

    /// A test script, a canonical notebook name and a grader-only file are in
    /// the zip, but none of them is a support file.
    @Test(arguments: ["t.sh", "assignment.ipynb", "answers.csv"])
    func supportFileRefusesAFileThatIsNotSupport(filename: String) async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = try await insertSupportSetup()
            let (status, _, _) = try await get(
                "/api/v1/testsetups/\(setupID)/support/\(filename)", cookie: session.cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func supportFileIsServedToAStudentAsAnAttachment() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSupportSetup()
            let cookie = try await loginAsStudent("gaps_student", on: app)
            let (status, headers, bytes) = try await get(
                "/api/v1/testsetups/\(setupID)/support/data.csv", cookie: cookie)
            #expect(status == .ok)
            #expect(String(bytes: bytes, encoding: .utf8) == "a,b\n1,2\n")
            #expect(headers.contentType?.subType == "csv")
            #expect(headers.first(name: .contentDisposition) == "attachment; filename=\"data.csv\"")
        }
    }

    @Test func supportFileOfAnUnopenedAssignmentRefusesAStudent() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSupportSetup(isOpen: false)
            let cookie = try await loginAsStudent("gaps_student", on: app)
            let (status, _, _) = try await get(
                "/api/v1/testsetups/\(setupID)/support/data.csv", cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    // MARK: - PUT /api/v1/testsetups/:id/assignment

    @Test func saveRefusesAnEmptyBody() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = try await insertSupportSetup()
            let status = try await put(
                "/api/v1/testsetups/\(setupID)/assignment", body: "", csrf: session.csrf, cookie: session.cookie)
            #expect(status == .badRequest)
        }
    }

    @Test func saveRefusesABodyThatIsNotJSON() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = try await insertSupportSetup()
            let status = try await put(
                "/api/v1/testsetups/\(setupID)/assignment", body: "not json",
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .unprocessableEntity)
            #expect(try await APITestSetup.find(setupID, on: app.db)?.notebookPath == nil)
        }
    }

    /// A setup that already has a notebook keeps its path: the save writes
    /// over that file and does not derive a new one.
    @Test func saveWritesOverTheExistingNotebookPath() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession()
            let setupID = "setup_gaps_existing"
            let existing = app.testSetupsDirectory + "custom-\(setupID).ipynb"
            try Data("{}".utf8).write(to: URL(fileURLWithPath: existing))
            let setup = APITestSetup(
                id: setupID, manifest: supportManifest, zipPath: app.testSetupsDirectory + "\(setupID).zip",
                notebookPath: existing, courseID: session.courseID)
            try await setup.save(on: app.db)

            let status = try await put(
                "/api/v1/testsetups/\(setupID)/assignment", body: notebookJSON,
                csrf: session.csrf, cookie: session.cookie)
            #expect(status == .noContent)
            #expect(try await APITestSetup.find(setupID, on: app.db)?.notebookPath == existing)
            #expect(try String(contentsOfFile: existing, encoding: .utf8).contains("x = 1"))
            #expect(!FileManager.default.fileExists(atPath: app.testSetupsDirectory + "\(setupID).ipynb"))
        }
    }
}
