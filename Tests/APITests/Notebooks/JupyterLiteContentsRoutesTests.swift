import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class JupyterLiteContentsRoutesTests {
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private let tmpRoot: String
    private let publicDir: String
    private let instructorUser: APIUser

    let app: Application

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-\(UUID().uuidString)/")
            .path
        let instructorUser = APIUser(
            id: UUID(),
            username: "jlite-test-instructor",
            passwordHash: "unused",
            role: "admin"
        )
        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            let publicDir = app.directory.publicDirectory
            app.middleware.use(InjectAuthMiddleware(user: instructorUser))

            try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: publicDir + "jupyterlite/files/",
                withIntermediateDirectories: true
            )
            // Recorded so the per-test `withApp` teardown removes the tree (#1298).
            app.testDataDirectory = tmpRoot
            // The contents routes now resolve the viewer's per-course staff status
            // through `req.db` (#417 Slice G), so the test app needs a database —
            // previously the route was filesystem-only.
            try await configureTestDatabase(app)
            try app.register(collection: JupyterLiteContentsRoutes())
        }
        self.tmpRoot = tmpRoot
        self.publicDir = app.directory.publicDirectory
        self.instructorUser = instructorUser
    }

    /// Staff read the authoring tree at the root; only a student's root is
    /// reduced to `users` (#2924).
    @Test func staffRootListsTheTree() async throws {
        try await withApp(app) { _ in
            let notebookName = "setup_root-listing.ipynb"
            try Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)
                .write(to: URL(fileURLWithPath: publicDir + "jupyterlite/files/" + notebookName))
            try await app.asyncTest(.GET, "/jupyterlite/api/contents?content=1") { res in
                #expect(res.status == .ok)
                let object = try #require(
                    try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any])
                let content = try #require(object["content"] as? [[String: Any]])
                #expect(content.contains { ($0["name"] as? String) == notebookName })
            }
        }
    }

    @Test func allJSONListsNotebook() async throws {
        try await withApp(app) { _ in
            let notebookName = "setup_test-assignment.ipynb"
            let notebookData = Data(
                """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}
                """.utf8)
            try notebookData.write(to: URL(fileURLWithPath: publicDir + "jupyterlite/files/" + notebookName))

            try await app.asyncTest(
                .GET, "/jupyterlite/lab/api/contents/all.json",
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let bodyData = Data(res.body.string.utf8)
                    let object = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                    #expect(object["type"] as? String == "directory")
                    let content = try #require(object["content"] as? [[String: Any]])
                    #expect(content.contains { ($0["name"] as? String) == notebookName })
                })

        }
    }

    @Test func notebookMetadataAndContent() async throws {
        try await withApp(app) { _ in
            let notebookName = "setup_test-assignment.ipynb"
            let notebookJSON = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":["hello"]}]}
                """
            try Data(notebookJSON.utf8).write(
                to: URL(fileURLWithPath: publicDir + "jupyterlite/files/" + notebookName)
            )

            try await app.asyncTest(
                .GET, "/jupyterlite/lab/api/contents/\(notebookName)",
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let bodyData = Data(res.body.string.utf8)
                    let object = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                    #expect(object["type"] as? String == "notebook")
                    #expect(object["format"] as? String == "json")
                    #expect(object["content"] is NSNull)
                })

            try await app.asyncTest(
                .GET, "/jupyterlite/lab/api/contents/\(notebookName)?content=1",
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let bodyData = Data(res.body.string.utf8)
                    let object = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                    #expect(object["type"] as? String == "notebook")
                    let content = try #require(object["content"] as? [String: Any])
                    let cells = try #require(content["cells"] as? [[String: Any]])
                    #expect(cells.count == 1)
                })

        }
    }

    private func model(_ path: String) async throws -> [String: Any] {
        var object: [String: Any] = [:]
        try await app.asyncTest(.GET, path) { res in
            #expect(res.status == .ok)
            object = try #require(
                try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any])
        }
        return object
    }

    /// A UTF-8 file comes back as text, and any other file as base64.
    @Test func fileContentIsTextOrBase64() async throws {
        try await withApp(app) { _ in
            let files = publicDir + "jupyterlite/files/"
            try Data("a,b\n1,2\n".utf8).write(to: URL(fileURLWithPath: files + "data.csv"))
            let binary = Data([0xff, 0xfe, 0x00, 0x80])
            try binary.write(to: URL(fileURLWithPath: files + "image.bin"))

            let text = try await model("/jupyterlite/api/contents/data.csv?content=1")
            #expect(text["type"] as? String == "file")
            #expect(text["format"] as? String == "text")
            #expect(text["mimetype"] as? String == "text/plain")
            #expect(text["content"] as? String == "a,b\n1,2\n")

            let base64 = try await model("/jupyterlite/api/contents/image.bin?content=1")
            #expect(base64["format"] as? String == "base64")
            #expect(base64["mimetype"] as? String == "application/octet-stream")
            #expect(base64["content"] as? String == binary.base64EncodedString())
            #expect(base64["size"] as? Int == binary.count)
        }
    }

    /// A folder lists its children by name, without regard to case.
    @Test func folderListsChildrenInCaseInsensitiveOrder() async throws {
        try await withApp(app) { _ in
            let folder = publicDir + "jupyterlite/files/ordered/"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for name in ["beta.txt", "Alpha.txt", "gamma.txt"] {
                try Data("x".utf8).write(to: URL(fileURLWithPath: folder + name))
            }
            let listing = try await model("/jupyterlite/api/contents/ordered?content=1")
            #expect(listing["type"] as? String == "directory")
            let content = try #require(listing["content"] as? [[String: Any]])
            #expect(content.compactMap { $0["name"] as? String } == ["Alpha.txt", "beta.txt", "gamma.txt"])
        }
    }

    @Test(arguments: [
        "/jupyterlite/api/contents/no-such-file.ipynb",
        "/jupyterlite/api/contents/no-such-folder/all.json",
    ])
    func aMissingFileOrFolderIsNotFound(path: String) async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(.GET, path) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    /// Staff read the whole drive, but never a path above it.
    @Test(arguments: [
        "/jupyterlite/api/contents/../../outside.txt",
        "/jupyterlite/api/contents/../../all.json",
    ])
    func staffCannotReadAboveTheDrive(path: String) async throws {
        try await withApp(app) { _ in
            // Two levels above `jupyterlite/files/` is `Public/`.
            try Data("above-the-drive".utf8).write(to: URL(fileURLWithPath: publicDir + "outside.txt"))
            try await app.asyncTest(.GET, path) { res in
                #expect(res.status == .forbidden)
                #expect(!res.body.string.contains("above-the-drive"))
            }
        }
    }
}
