// Tests/APITests/Notebooks/JupyterLiteContentsUserFolderTests.swift
//
// The JupyterLite contents API applies `mayReadUserFile` to another user's
// folder (#2895). Before #2895 a TA in any live course read every user's
// folder through it, including other courses' solution notebooks.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct JupyterLiteContentsUserFolderTests {

    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private static let owner = "0a1b2c3d-0000-4000-8000-0000000000aa"
    private static let setupID = "setup_jlc"

    /// An app whose caller is a TA in the course named `taCourse`. The setup
    /// lives in course "OWN"; a student's notebook sits in its folder.
    private func withContentsApp(
        taCourse: String, _ body: @Sendable (Application) async throws -> Void
    ) async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlc-\(UUID().uuidString)/").path
        let ta = APIUser(id: UUID(), username: "jlc-ta", passwordHash: "unused", role: "student")
        let app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            let files = app.directory.publicDirectory + "jupyterlite/files/"
            let folder = files + "users/\(Self.owner)/\(Self.setupID)/"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: files + "shared/", withIntermediateDirectories: true)
            try Data(#"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#.utf8)
                .write(to: URL(fileURLWithPath: folder + "assignment.ipynb"))
            app.testDataDirectory = tmpRoot
            try await configureTestDatabase(app)
            app.middleware.use(InjectAuthMiddleware(user: ta))
            try app.register(collection: JupyterLiteContentsRoutes())
        }
        try await withApp(app) { app in
            try await ta.save(on: app.db)
            let own = try await makeTestCourse(on: app, code: "OWN", mode: .closed)
            let other = try await makeTestCourse(on: app, code: "OTHER", mode: .closed)
            try await APITestSetup(
                id: Self.setupID, manifest: TestManifests.browserEmpty, zipPath: "unused.zip",
                courseID: try own.requireID()
            ).save(on: app.db)
            let staffed = taCourse == "OWN" ? own : other
            try await APICourseEnrollment(
                userID: try ta.requireID(), courseID: try staffed.requireID(), role: .ta
            ).save(on: app.db)
            try await body(app)
        }
    }

    private func status(_ app: Application, _ path: String) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(.GET, path) { res in status = res.status }
        return status
    }

    private static let notebook = "/jupyterlite/api/contents/users/\(owner)/\(setupID)/assignment.ipynb"

    @Test func aTAOfTheSetupsCourseReadsTheNotebook() async throws {
        try await withContentsApp(taCourse: "OWN") { app in
            let result = try await status(app, Self.notebook)
            #expect(result == .ok)
        }
    }

    @Test(arguments: [
        notebook,
        "/jupyterlite/api/contents/shared/../users/\(owner)/\(setupID)/assignment.ipynb",
        "/jupyterlite/api/contents/Users/\(owner)/\(setupID)/assignment.ipynb",
    ])
    func aTAOfAnotherCourseIsRefused(path: String) async throws {
        try await withContentsApp(taCourse: "OTHER") { app in
            let result = try await status(app, path)
            #expect(result == .forbidden)
        }
    }

    /// A listing above a setup names every user, so even a TA of the setup's
    /// course is refused it.
    @Test(arguments: [
        "/jupyterlite/api/contents/users/all.json",
        "/jupyterlite/api/contents/users/\(owner)/all.json",
    ])
    func listingsAboveASetupAreRefused(path: String) async throws {
        try await withContentsApp(taCourse: "OWN") { app in
            let result = try await status(app, path)
            #expect(result == .forbidden)
        }
    }

    /// The kernel's file system reads `users` on its way to a staff draft
    /// (#2925). A 403 there kept the kernel from booting on WebKit (2026-11),
    /// so a TA who is not an admin reads `users` as a student does: one child,
    /// their own folder, and no other user named.
    @Test func aTAReadsUsersAsTheirOwnFolderOnly() async throws {
        try await withContentsApp(taCourse: "OWN") { app in
            try await app.asyncTest(.GET, "/jupyterlite/api/contents/users?content=1") { res in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains(#""type":"directory""#))
                #expect(!body.contains(Self.owner))
                let ta = try await APIUser.query(on: app.db).filter(\.$username == "jlc-ta").first()
                let taID = try #require(ta?.id).uuidString.lowercased()
                #expect(body.contains(taID))
            }
        }
    }
}
