import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The guard rails on the server-backed editor drive (#469): a write route
/// refuses the files the assignment provides (its datasets and support files)
/// and the read-only submission records, and a rename that would move one.
/// A student's own files and the notebook stay writable.
@Suite(.serialized, .timeLimit(.minutes(2))) final class JupyterLiteContentsProtectedFilesTests {
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private static let setupID = "setup_guard"
    private static let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null,\
        "datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":2}]}
        """

    private let tmpRoot: String
    private let filesDir: String
    private let setupDir: String

    let app: Application

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-guard-\(UUID().uuidString)/")
            .path
        let student = APIUser(id: UUID(), username: "jlite-guard-student", passwordHash: "unused", role: "user")
        let studentID = try #require(student.id).uuidString.lowercased()
        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            app.middleware.use(InjectAuthMiddleware(user: student))
            app.testDataDirectory = tmpRoot
            try await configureTestDatabase(app)
            try app.register(collection: JupyterLiteContentsRoutes())
        }
        self.tmpRoot = tmpRoot
        self.filesDir = app.directory.publicDirectory + "jupyterlite/files/"
        self.setupDir = "users/\(studentID)/\(Self.setupID)"
        try FileManager.default.createDirectory(
            atPath: filesDir + setupDir + "/lib", withIntermediateDirectories: true)
        for name in ["cases.csv", "lib/helper.py", "view-sub_1.ipynb", "assignment.ipynb"] {
            try Data("original".utf8).write(to: URL(fileURLWithPath: filesDir + setupDir + "/" + name))
        }
    }

    /// The setup row and its zip: a dataset, a support file in a folder, and
    /// the suite script, which the working copy does not hold.
    private func seedSetup() async throws {
        let course = APICourse(code: "GUARD101", name: "Guard Course")
        try await course.save(on: app.db)
        let zipPath = tmpRoot + "setup_guard.zip"
        try await writeZipFixture(
            at: zipPath, entries: [("cases.csv", "a,b\n"), ("lib/helper.py", "x = 1\n"), ("tests.py", "pass\n")])
        try await APITestSetup(
            id: Self.setupID, manifest: Self.manifest, zipPath: zipPath, courseID: try course.requireID()
        ).save(on: app.db)
    }

    private func put(_ inside: String, check: @escaping (TestResponse) throws -> Void) async throws {
        try await app.asyncTest(
            .PUT, "/jupyterlite/api/contents/\(setupDir)/\(inside)",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(string: #"{"type":"file","format":"text","content":"changed"}"#)
            },
            afterResponse: { res in try check(res) })
    }

    private func rename(_ from: String, to: String, check: @escaping (TestResponse) throws -> Void) async throws {
        try await app.asyncTest(
            .PATCH, "/jupyterlite/api/contents/\(from)",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(string: #"{"path":"\#(to)"}"#)
            },
            afterResponse: { res in try check(res) })
    }

    private func contents(_ inside: String) throws -> String {
        try String(contentsOfFile: filesDir + setupDir + "/" + inside, encoding: .utf8)
    }

    @Test(arguments: ["cases.csv", "lib/helper.py", "view-sub_1.ipynb", "view-sub_2.ipynb"])
    func refusesAWriteToAProvidedFile(inside: String) async throws {
        try await withApp(app) { _ in
            try await seedSetup()
            try await put(inside) { res in #expect(res.status == .forbidden, "\(inside)") }
            if inside != "view-sub_2.ipynb" {
                #expect(try contents(inside) == "original")
            }
        }
    }

    @Test func theNotebookAndTheStudentsOwnFilesStayWritable() async throws {
        try await withApp(app) { _ in
            try await seedSetup()
            try await put("assignment.ipynb") { res in #expect(res.status == .ok) }
            try await put("results.csv") { res in #expect(res.status == .ok) }
            try await put("lib/mine.py") { res in #expect(res.status == .ok) }
            #expect(try contents("results.csv") == "changed")
        }
    }

    @Test func refusesARenameThatMovesAProvidedFile() async throws {
        try await withApp(app) { _ in
            try await seedSetup()
            let dir = setupDir
            // The dataset away, a file onto the dataset, the folder holding a
            // support file, and the assignment folder itself.
            try await rename("\(dir)/cases.csv", to: "\(dir)/old.csv") { res in #expect(res.status == .forbidden) }
            try await put("mine.csv") { res in #expect(res.status == .ok) }
            try await rename("\(dir)/mine.csv", to: "\(dir)/cases.csv") { res in #expect(res.status == .forbidden) }
            try await rename("\(dir)/lib", to: "\(dir)/lib2") { res in #expect(res.status == .forbidden) }
            try await rename(dir, to: "\(dir)-moved") { res in #expect(res.status == .forbidden) }
            #expect(try contents("cases.csv") == "original")
            #expect(try contents("lib/helper.py") == "original")
            // The student's own file still renames.
            try await rename("\(dir)/mine.csv", to: "\(dir)/kept.csv") { res in #expect(res.status == .ok) }
        }
    }
}
