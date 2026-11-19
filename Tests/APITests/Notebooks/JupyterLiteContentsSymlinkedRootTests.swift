import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The production image links `Public/jupyterlite/files` to the data volume
/// (`Dockerfile`: `ln -s /data/jupyterlite-files ./Public/jupyterlite/files`).
/// The drive root is that link itself, and a staff listing of it must not
/// answer 404: on the server drive, JupyterLab's file browser polls the root
/// and shows "Directory not found" for every 404.
@Suite(.serialized) final class JupyterLiteContentsSymlinkedRootTests {
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private let dataDir: String
    let app: Application

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-link-\(UUID().uuidString)/")
            .path
        let dataDir = tmpRoot + "data/jupyterlite-files"
        let staff = APIUser(id: UUID(), username: "jlite-link-staff", passwordHash: "unused", role: "admin")
        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            let publicDir = app.directory.publicDirectory
            app.middleware.use(InjectAuthMiddleware(user: staff))
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: publicDir + "jupyterlite", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: publicDir + "jupyterlite/files", withDestinationPath: dataDir)
            app.testDataDirectory = tmpRoot
            try await configureTestDatabase(app)
            try app.register(collection: JupyterLiteContentsRoutes())
        }
        self.dataDir = dataDir
    }

    @Test func staffRootThroughALinkListsTheTree() async throws {
        try await withApp(app) { _ in
            let notebookName = "setup_linked-root.ipynb"
            try Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)
                .write(to: URL(fileURLWithPath: dataDir + "/" + notebookName))
            for path in ["/jupyterlite/api/contents?content=1&hash=0", "/jupyterlite/api/contents/all.json"] {
                try await app.asyncTest(.GET, path) { res in
                    #expect(res.status == .ok, "\(path)")
                    let object = try #require(
                        try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any])
                    #expect(object["type"] as? String == "directory")
                    let content = try #require(object["content"] as? [[String: Any]])
                    #expect(content.contains { ($0["name"] as? String) == notebookName }, "\(path)")
                }
            }
        }
    }
}
