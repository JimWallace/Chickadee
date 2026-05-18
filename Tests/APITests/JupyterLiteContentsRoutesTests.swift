import Fluent
import Foundation
import Testing
import Vapor
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class JupyterLiteContentsRoutesTests {
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private var tmpRoot: String!
    private var publicDir: String!
    private var instructorUser: APIUser!

    let app: Application

    init() async throws {
        self.app = try await Application.make(.testing)

        tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-\(UUID().uuidString)/")
            .path
        app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
        publicDir = app.directory.publicDirectory
        instructorUser = APIUser(
            id: UUID(),
            username: "jlite-test-instructor",
            passwordHash: "unused",
            role: "admin"
        )
        app.middleware.use(InjectAuthMiddleware(user: instructorUser))

        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: publicDir + "jupyterlite/files/",
            withIntermediateDirectories: true
        )
        try app.register(collection: JupyterLiteContentsRoutes())
    }

    deinit {
        let appLocal = app
        Task { try? await appLocal.asyncShutdown() }
    }

    @Test func allJSONListsNotebook() async throws {
        let notebookName = "setup_test-assignment.ipynb"
        let notebookData = """
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}
            """.data(using: .utf8)!
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

    @Test func notebookMetadataAndContent() async throws {
        let notebookName = "setup_test-assignment.ipynb"
        let notebookJSON = """
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":["hello"]}]}
            """
        try notebookJSON.data(using: .utf8)!.write(
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
