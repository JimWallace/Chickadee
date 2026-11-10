import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A student's notebook is stored as code only: a save to their copy of an
/// assignment clears every code cell's outputs. Staff copies keep their
/// outputs, because the assignment and the solution are saved from them.
@Suite(.serialized, .timeLimit(.minutes(2))) final class JupyterLiteContentsOutputStrippingTests {
    /// Signs in the user the `X-Test-User` header names: "ta", else the student.
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let student: APIUser
        let ta: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(request.headers.first(name: "X-Test-User") == "ta" ? ta : student)
            return try await next.respond(to: request)
        }
    }

    private static let setupID = "setup_strip"

    /// A code cell with an image output and an execution count, and a
    /// markdown cell with a pasted image.
    private static let notebook = #"""
        {"type":"notebook","format":"json","content":{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"code","id":"c1","metadata":{},"execution_count":3,"source":"plot(x)",
         "outputs":[{"output_type":"display_data","metadata":{},"data":{"image/png":"iVBORw0KGgo="}}]},
        {"cell_type":"markdown","id":"m1","metadata":{},"source":"![a](attachment:a.png)",
         "attachments":{"a.png":{"image/png":"iVBORw0KGgo="}}}]}}
        """#

    private static let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}
        """

    private let student: APIUser
    private let ta: APIUser
    private let filesDir: String
    private let setupZipPath: String

    let app: Application

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-strip-\(UUID().uuidString)/")
            .path
        let student = APIUser(id: UUID(), username: "jlite-strip-student", passwordHash: "unused", role: "user")
        let ta = APIUser(id: UUID(), username: "jlite-strip-ta", passwordHash: "unused", role: "user")
        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            app.middleware.use(InjectAuthMiddleware(student: student, ta: ta))
            app.testDataDirectory = tmpRoot
            try await configureTestDatabase(app)
            try app.register(collection: JupyterLiteContentsRoutes())
        }
        self.student = student
        self.ta = ta
        self.filesDir = app.directory.publicDirectory + "jupyterlite/files/"
        self.setupZipPath = tmpRoot + "setup.zip"
        try await writeZipFixture(at: setupZipPath, entries: [("tests.py", "pass\n")])
    }

    private func root(of user: APIUser) throws -> String {
        "users/\(try #require(user.id).uuidString.lowercased())"
    }

    private func seed() async throws {
        try await student.save(on: app.db)
        try await ta.save(on: app.db)
        let course = APICourse(code: "STRIP101", name: "Strip Course")
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        // The assignment row references its setup row.
        try await APITestSetup(
            id: Self.setupID, manifest: Self.manifest, zipPath: setupZipPath, courseID: courseID
        ).save(on: app.db)
        try await APICourseEnrollment(userID: try student.requireID(), courseID: courseID, role: .student)
            .save(on: app.db)
        try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta).save(on: app.db)
        try await APIAssignment(testSetupID: Self.setupID, title: "Strip", visibility: .open, courseID: courseID)
            .save(on: app.db)
        for user in [student, ta] {
            try FileManager.default.createDirectory(
                atPath: filesDir + (try root(of: user)) + "/" + Self.setupID, withIntermediateDirectories: true)
        }
    }

    private func save(_ path: String, as who: String = "student") async throws {
        try await app.asyncTest(
            .PUT, "/jupyterlite/api/contents/\(path)",
            beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-Test-User", value: who)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: Self.notebook)
            },
            afterResponse: { res in #expect(res.status == .ok) })
    }

    /// The stored notebook's cells.
    private func cells(_ path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: filesDir + path))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["cells"] as? [[String: Any]])
    }

    @Test func aStudentsNotebookIsStoredWithoutOutputs() async throws {
        try await withApp(app) { _ in
            try await seed()
            let path = try root(of: student) + "/\(Self.setupID)/assignment.ipynb"
            try await save(path)
            let stored = try cells(path)
            #expect((stored[0]["outputs"] as? [Any])?.isEmpty == true)
            #expect(stored[0]["execution_count"] is NSNull)
            #expect(stored[0]["source"] as? String == "plot(x)")
            // A pasted image in a markdown cell is the student's content.
            #expect(stored[1]["attachments"] != nil)
        }
    }

    @Test func aStaffCopyKeepsItsOutputs() async throws {
        try await withApp(app) { _ in
            try await seed()
            let path = try root(of: ta) + "/\(Self.setupID)/assignment.ipynb"
            try await save(path, as: "ta")
            let stored = try cells(path)
            #expect((stored[0]["outputs"] as? [Any])?.count == 1)
            #expect(stored[0]["execution_count"] as? Int == 3)
        }
    }

    /// A folder that names no assignment is the student's own scratch space,
    /// not an assignment copy, and is stored as written.
    @Test func aNotebookOutsideAnAssignmentIsStoredAsWritten() async throws {
        try await withApp(app) { _ in
            try await seed()
            let path = try root(of: student) + "/scratch/mine.ipynb"
            try await save(path)
            #expect((try cells(path)[0]["outputs"] as? [Any])?.count == 1)
        }
    }
}
