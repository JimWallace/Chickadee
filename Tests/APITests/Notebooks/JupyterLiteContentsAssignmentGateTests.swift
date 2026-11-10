import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A student writes the working copy of an assignment only while it is open to
/// them (#2927): a save, a rename and a new folder into a closed or not-yet-open
/// assignment are refused, as the notebook reset is. Course staff keep writing
/// their own copies of a closed assignment.
@Suite(.serialized, .timeLimit(.minutes(2))) final class JupyterLiteContentsAssignmentGateTests {
    /// Signs in the user the `X-Test-User` header names: "ta", else the student.
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let student: APIUser
        let ta: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(request.headers.first(name: "X-Test-User") == "ta" ? ta : student)
            return try await next.respond(to: request)
        }
    }

    private static let setupID = "setup_gate"

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
            .appendingPathComponent("chickadee-jlite-gate-\(UUID().uuidString)/")
            .path
        let student = APIUser(id: UUID(), username: "jlite-gate-student", passwordHash: "unused", role: "user")
        let ta = APIUser(id: UUID(), username: "jlite-gate-ta", passwordHash: "unused", role: "user")
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

    private func folder(of user: APIUser) throws -> String {
        "users/\(try #require(user.id).uuidString.lowercased())/\(Self.setupID)"
    }

    /// The course, both enrollments and the assignment, in `visibility`.
    private func seed(visibility: AssignmentVisibility, startsAt: Date? = nil) async throws {
        try await student.save(on: app.db)
        try await ta.save(on: app.db)
        let course = APICourse(code: "GATE101", name: "Gate Course")
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        // The assignment row references its setup row.
        try await APITestSetup(
            id: Self.setupID, manifest: Self.manifest, zipPath: setupZipPath, courseID: courseID
        ).save(on: app.db)
        try await APICourseEnrollment(userID: try student.requireID(), courseID: courseID, role: .student)
            .save(on: app.db)
        try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta).save(on: app.db)
        try await APIAssignment(
            testSetupID: Self.setupID, title: "Gate", startsAt: startsAt, visibility: visibility,
            courseID: courseID
        ).save(on: app.db)
        for user in [student, ta] {
            let dir = filesDir + (try folder(of: user))
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: URL(fileURLWithPath: dir + "/assignment.ipynb"))
        }
    }

    private func put(
        _ path: String, as who: String = "student", expecting expected: HTTPStatus,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var status = HTTPStatus.ok
        try await app.asyncTest(
            .PUT, "/jupyterlite/api/contents/\(path)",
            beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-Test-User", value: who)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: #"{"type":"file","format":"text","content":"changed"}"#)
            },
            afterResponse: { res in status = res.status })
        #expect(status == expected, sourceLocation: sourceLocation)
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: filesDir + path, encoding: .utf8)
    }

    @Test func aStudentSavesIntoAnOpenAssignment() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .open)
            let path = try folder(of: student) + "/assignment.ipynb"
            try await put(path, expecting: .ok)
            #expect(try contents(path) == "changed")
        }
    }

    @Test func aStudentCannotSaveIntoAClosedAssignment() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .closed)
            let path = try folder(of: student) + "/assignment.ipynb"
            try await put(path, expecting: .forbidden)
            try await put(try folder(of: student) + "/new.csv", expecting: .forbidden)
            #expect(try contents(path) == "original")
        }
    }

    @Test func aStudentCannotSaveBeforeTheAssignmentOpens() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .open, startsAt: Date().addingTimeInterval(86_400))
            let path = try folder(of: student) + "/assignment.ipynb"
            try await put(path, expecting: .forbidden)
            #expect(try contents(path) == "original")
        }
    }

    @Test func aStudentCannotRenameOrCreateAFolderInAClosedAssignment() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .closed)
            let dir = try folder(of: student)
            try await app.asyncTest(
                .PATCH, "/jupyterlite/api/contents/\(dir)/assignment.ipynb",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"path":"\#(dir)/renamed.ipynb"}"#)
                },
                afterResponse: { res in #expect(res.status == .forbidden) })
            try await app.asyncTest(
                .POST, "/jupyterlite/api/contents/\(dir)",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"type":"directory"}"#)
                },
                afterResponse: { res in #expect(res.status == .forbidden) })
            #expect(try contents(dir + "/assignment.ipynb") == "original")
            #expect(!FileManager.default.fileExists(atPath: filesDir + dir + "/Untitled Folder"))
        }
    }

    @Test func courseStaffStillSaveTheirCopyOfAClosedAssignment() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .closed)
            let path = try folder(of: ta) + "/assignment.ipynb"
            try await put(path, as: "ta", expecting: .ok)
            #expect(try contents(path) == "changed")
        }
    }

    /// A folder that names no assignment (a student's own top-level folder)
    /// is not gated.
    @Test func aFolderThatNamesNoAssignmentIsNotGated() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .closed)
            let root = "users/\(try #require(student.id).uuidString.lowercased())"
            try FileManager.default.createDirectory(
                atPath: filesDir + root + "/scratch", withIntermediateDirectories: true)
            try await put(root + "/scratch/notes.txt", expecting: .ok)
        }
    }

    /// A file in a copy the gate would refuse reads as read-only, so the
    /// editor opens it without autosave.
    @Test(arguments: [
        (AssignmentVisibility.open, "student", true),
        (.closed, "student", false),
        (.closed, "ta", true),
    ])
    func aFileReadsAsWritableOnlyWhereASaveWouldLand(
        visibility: AssignmentVisibility, who: String, writable: Bool
    )
        async throws
    {
        try await withApp(app) { _ in
            try await seed(visibility: visibility)
            let path = try folder(of: who == "ta" ? ta : student) + "/assignment.ipynb"
            try await app.asyncTest(
                .GET, "/jupyterlite/api/contents/\(path)",
                beforeRequest: { req in req.headers.replaceOrAdd(name: "X-Test-User", value: who) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let model = try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
                    #expect(model?["writable"] as? Bool == writable)
                })
        }
    }

    /// Course staff are not under the storage quota: their copies keep outputs.
    @Test func courseStaffAreNotUnderTheStorageQuota() async throws {
        try await withApp(app) { _ in
            try await seed(visibility: .open)
            app.jupyterLiteContentsWriteLimits = JupyterLiteContentsWriteLimits(
                maxUserFolderBytes: 1, writesPerMinute: 1_000)
            // New files, so each save grows the folder.
            try await put(try folder(of: ta) + "/notes.txt", as: "ta", expecting: .ok)
            try await put(try folder(of: student) + "/notes.txt", expecting: .payloadTooLarge)
        }
    }
}
