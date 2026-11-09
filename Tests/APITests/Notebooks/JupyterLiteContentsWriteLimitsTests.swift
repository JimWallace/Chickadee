import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The limits on the editor's contents write routes (#2926): a per-user storage
/// quota on a save that grows the user's files, and a per-user rate limit.
/// The quota counts only what the routes can write, so a shared dataset linked
/// into the working copy and a delivered dataset never stop a save.
@Suite(.serialized, .timeLimit(.minutes(2))) final class JupyterLiteContentsWriteLimitsTests {
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private static let setupID = "setup_limits"
    private static let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null,\
        "datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":2}]}
        """

    private let tmpRoot: String
    private let filesDir: String
    private let userRoot: String
    private let setupDir: String

    let app: Application

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-limits-\(UUID().uuidString)/")
            .path
        let student = APIUser(id: UUID(), username: "jlite-limits-student", passwordHash: "unused", role: "user")
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
        self.userRoot = "users/\(studentID)"
        self.setupDir = "users/\(studentID)/\(Self.setupID)"
        try FileManager.default.createDirectory(atPath: filesDir + setupDir, withIntermediateDirectories: true)
    }

    private func put(_ inside: String, bytes: Int) async throws -> HTTPStatus {
        var status = HTTPStatus.ok
        let content = String(repeating: "x", count: bytes)
        try await app.asyncTest(
            .PUT, "/jupyterlite/api/contents/\(setupDir)/\(inside)",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(string: #"{"type":"file","format":"text","content":"\#(content)"}"#)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func limit(quota: Int = 1_000_000, perMinute: Int = 1_000) {
        app.jupyterLiteContentsWriteLimits = JupyterLiteContentsWriteLimits(
            maxUserFolderBytes: quota, writesPerMinute: perMinute)
    }

    @Test func refusesASaveThatWouldPassTheQuota() async throws {
        try await withApp(app) { _ in
            limit(quota: 100)
            #expect(try await put("a.txt", bytes: 60) == .ok)
            #expect(try await put("b.txt", bytes: 50) == .payloadTooLarge)
            #expect(!FileManager.default.fileExists(atPath: filesDir + setupDir + "/b.txt"))
            // Rewriting a file counts its new size in place of its old one.
            #expect(try await put("a.txt", bytes: 90) == .ok)
        }
    }

    @Test func aSaveThatDoesNotGrowAFileLandsEvenOverTheQuota() async throws {
        try await withApp(app) { _ in
            limit(quota: 100)
            #expect(try await put("big.txt", bytes: 90) == .ok)
            limit(quota: 10)
            #expect(try await put("big.txt", bytes: 40) == .ok)
            #expect(try await put("other.txt", bytes: 1) == .payloadTooLarge)
        }
    }

    @Test func theServersFilesDoNotCountTowardTheQuota() async throws {
        try await withApp(app) { _ in
            // A delivered dataset (a real file), a submission record and a
            // shared dataset linked in: each well over the quota.
            let course = APICourse(code: "LIMIT101", name: "Limit Course")
            try await course.save(on: app.db)
            let zipPath = tmpRoot + "setup_limits.zip"
            try await writeZipFixture(at: zipPath, entries: [("cases.csv", "a,b\n"), ("tests.py", "pass\n")])
            try await APITestSetup(
                id: Self.setupID, manifest: Self.manifest, zipPath: zipPath, courseID: try course.requireID()
            ).save(on: app.db)
            let big = Data(repeating: 0x61, count: 500)
            try big.write(to: URL(fileURLWithPath: filesDir + setupDir + "/cases.csv"))
            try big.write(to: URL(fileURLWithPath: filesDir + setupDir + "/view-sub_1.ipynb"))
            try big.write(to: URL(fileURLWithPath: tmpRoot + "shared.csv"))
            try FileManager.default.createSymbolicLink(
                atPath: filesDir + setupDir + "/shared.csv", withDestinationPath: tmpRoot + "shared.csv")

            limit(quota: 100)
            #expect(try await put("assignment.ipynb", bytes: 80) == .ok)
            // The student's own file in another folder does count.
            try FileManager.default.createDirectory(
                atPath: filesDir + userRoot + "/scratch", withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 30).write(to: URL(fileURLWithPath: filesDir + userRoot + "/scratch/x"))
            #expect(try await put("more.txt", bytes: 1) == .payloadTooLarge)
        }
    }

    @Test func rateLimitsWritesPerUser() async throws {
        try await withApp(app) { _ in
            limit(perMinute: 2)
            #expect(try await put("a.txt", bytes: 1) == .ok)
            #expect(try await put("a.txt", bytes: 1) == .ok)
            try await app.asyncTest(
                .PUT, "/jupyterlite/api/contents/\(setupDir)/a.txt",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"type":"file","format":"text","content":"x"}"#)
                },
                afterResponse: { res in
                    #expect(res.status == .tooManyRequests)
                    #expect(res.headers.first(name: "Retry-After") == "60")
                })
        }
    }

    @Test func readsAreNotRateLimited() async throws {
        try await withApp(app) { _ in
            limit(perMinute: 1)
            #expect(try await put("a.txt", bytes: 1) == .ok)
            for _ in 0..<3 {
                try await app.asyncTest(.GET, "/jupyterlite/api/contents/\(setupDir)/a.txt") { res in
                    #expect(res.status == .ok)
                }
            }
        }
    }
}
