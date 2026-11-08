import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The write half of the contents API, for the server-backed editor drive
/// (#469 spike, JupyterLiteContentsRoutes+Write.swift). Pins the save round
/// trip and, above all, the scope: a caller writes only under their own
/// `users/<id>/` folder, never through a symlink into a shared directory.
@Suite(.serialized) final class JupyterLiteContentsWriteRoutesTests {
    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private let filesDir: String
    private let userRoot: String
    private let otherRoot: String
    private let sharedDir: String

    let app: Application

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-write-\(UUID().uuidString)/")
            .path
        let student = APIUser(id: UUID(), username: "jlite-write-student", passwordHash: "unused", role: "user")
        let studentID = try #require(student.id).uuidString.lowercased()
        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            app.middleware.use(InjectAuthMiddleware(user: student))
            app.testDataDirectory = tmpRoot
            try await configureTestDatabase(app)
            try app.register(collection: JupyterLiteContentsRoutes())
        }
        let filesDir = app.directory.publicDirectory + "jupyterlite/files/"
        self.filesDir = filesDir
        self.userRoot = "users/\(studentID)"
        self.otherRoot = "users/\(UUID().uuidString.lowercased())"
        self.sharedDir = tmpRoot + "shared/"
        let fm = FileManager.default
        try fm.createDirectory(atPath: filesDir + userRoot + "/setup_a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: filesDir + otherRoot + "/setup_a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: URL(fileURLWithPath: sharedDir + "data.csv"))
        // A support file and a dataset directory, as the working copy links them.
        try fm.createSymbolicLink(
            atPath: filesDir + userRoot + "/setup_a/data.csv", withDestinationPath: sharedDir + "data.csv")
        try fm.createSymbolicLink(atPath: filesDir + userRoot + "/setup_a/pool", withDestinationPath: sharedDir)
    }

    private func put(
        _ path: String, _ body: String, check: @escaping (TestResponse) throws -> Void
    )
        async throws
    {
        try await app.asyncTest(
            .PUT, "/jupyterlite/api/contents/\(path)",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            },
            afterResponse: { res in try check(res) })
    }

    private func object(_ res: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any])
    }

    @Test func savesANotebookIntoTheCallersFolder() async throws {
        try await withApp(app) { _ in
            let path = "\(userRoot)/setup_a/assignment.ipynb"
            let body = #"{"type":"notebook","format":"json","content":{"nbformat":4,"cells":[],"metadata":{}}}"#
            try await put(path, body) { res in
                #expect(res.status == .ok)
                let model = try self.object(res)
                #expect(model["type"] as? String == "notebook")
                #expect(model["path"] as? String == path)
                #expect(model["content"] is NSNull)
                #expect(model["last_modified"] is String)
            }
            let written = try String(contentsOfFile: filesDir + path, encoding: .utf8)
            #expect(written.contains(#""nbformat" : 4"#))
            // Sorted keys: `cells` before `metadata` before `nbformat`.
            let cells = try #require(written.range(of: "cells"))
            let nbformat = try #require(written.range(of: "nbformat"))
            #expect(cells.lowerBound < nbformat.lowerBound)
        }
    }

    @Test func savesTextBase64AndEmptyFiles() async throws {
        try await withApp(app) { _ in
            let dir = "\(userRoot)/setup_a"
            try await put("\(dir)/a.txt", #"{"type":"file","format":"text","content":"hello"}"#) { res in
                #expect(res.status == .ok)
            }
            try await put("\(dir)/b.bin", #"{"type":"file","format":"base64","content":"AAEC"}"#) { res in
                #expect(res.status == .ok)
            }
            // The kernel's file system creates a file with no content (mknod).
            try await put("\(dir)/c.txt", #"{"type":"file"}"#) { res in
                #expect(res.status == .ok)
            }
            #expect(try String(contentsOfFile: filesDir + dir + "/a.txt", encoding: .utf8) == "hello")
            #expect(try Data(contentsOf: URL(fileURLWithPath: filesDir + dir + "/b.bin")) == Data([0, 1, 2]))
            #expect(try Data(contentsOf: URL(fileURLWithPath: filesDir + dir + "/c.txt")).isEmpty)
        }
    }

    @Test(arguments: [
        "OTHER/setup_a/x.txt",
        "x.txt",
        "users/x.txt",
        "OWN/setup_a/../../OTHER/setup_a/x.txt",
        "OWN/setup_a/data.csv",
        "OWN/setup_a/pool/data.csv",
        "OWN/setup_a/pool/new.txt",
    ])
    func refusesAWriteOutsideTheCallersOwnFiles(template: String) async throws {
        try await withApp(app) { _ in
            let path = template.replacingOccurrences(of: "OWN", with: userRoot)
                .replacingOccurrences(of: "OTHER", with: otherRoot)
            try await put(path, #"{"type":"file","format":"text","content":"overwritten"}"#) { res in
                #expect(res.status == .forbidden, "\(path)")
            }
            #expect(try String(contentsOfFile: sharedDir + "data.csv", encoding: .utf8) == "shared")
            #expect(!FileManager.default.fileExists(atPath: sharedDir + "new.txt"))
            #expect(!FileManager.default.fileExists(atPath: filesDir + otherRoot + "/setup_a/x.txt"))
        }
    }

    @Test func usersListsOnlyTheCallersOwnFolder() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(.GET, "/jupyterlite/api/contents/users?content=1") { res in
                #expect(res.status == .ok)
                let model = try self.object(res)
                #expect(model["type"] as? String == "directory")
                let children = try #require(model["content"] as? [[String: Any]])
                #expect(children.map { $0["path"] as? String } == [self.userRoot])
            }
        }
    }

    @Test func checkpointsAreStubs() async throws {
        try await withApp(app) { _ in
            let path = "\(userRoot)/setup_a/assignment.ipynb"
            try Data("{}".utf8).write(to: URL(fileURLWithPath: filesDir + path))
            try await app.asyncTest(.GET, "/jupyterlite/api/contents/\(path)/checkpoints") { res in
                #expect(res.status == .ok)
                let list = try #require(
                    try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [[String: Any]])
                #expect(list.count == 1)
                #expect(list.first?["id"] as? String == "checkpoint")
            }
            try await app.asyncTest(.POST, "/jupyterlite/api/contents/\(path)/checkpoints") { res in
                #expect(res.status == .created)
            }
            try await app.asyncTest(.DELETE, "/jupyterlite/api/contents/\(path)/checkpoints/checkpoint") { res in
                #expect(res.status == .noContent)
            }
            let othersCheckpoints = "/jupyterlite/api/contents/\(otherRoot)/setup_a/x.ipynb/checkpoints"
            try await app.asyncTest(.GET, othersCheckpoints) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func aRealCheckpointsFolderIsNotShadowedByTheStub() async throws {
        try await withApp(app) { _ in
            let folder = "\(userRoot)/setup_a/checkpoints"
            try FileManager.default.createDirectory(atPath: filesDir + folder, withIntermediateDirectories: true)
            try Data("w".utf8).write(to: URL(fileURLWithPath: filesDir + folder + "/model.pkl"))
            try await app.asyncTest(.GET, "/jupyterlite/api/contents/\(folder)?content=1") { res in
                #expect(res.status == .ok)
                let model = try self.object(res)
                #expect(model["type"] as? String == "directory")
            }
            // Not a checkpoint delete: refused, and the file is still there.
            try await app.asyncTest(.DELETE, "/jupyterlite/api/contents/\(folder)/model.pkl") { res in
                #expect(res.status == .methodNotAllowed)
            }
            #expect(FileManager.default.fileExists(atPath: filesDir + folder + "/model.pkl"))
        }
    }

    @Test func refusesADirectoryOverAFileAndARenameIntoNoFolder() async throws {
        try await withApp(app) { _ in
            let dir = "\(userRoot)/setup_a"
            try Data("x".utf8).write(to: URL(fileURLWithPath: filesDir + dir + "/f.txt"))
            try await put("\(dir)/f.txt", #"{"type":"directory"}"#) { res in
                #expect(res.status == .conflict)
            }
            try await app.asyncTest(
                .PATCH, "/jupyterlite/api/contents/\(dir)/f.txt",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"path":"\#(dir)/missing/f.txt"}"#)
                },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    @Test func makesADirectoryAsTheKernelDoes() async throws {
        try await withApp(app) { _ in
            let dir = "\(userRoot)/setup_a"
            var created = ""
            try await app.asyncTest(
                .POST, "/jupyterlite/api/contents/\(dir)",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"type":"directory"}"#)
                },
                afterResponse: { res in
                    #expect(res.status == .created)
                    created = try #require(try self.object(res)["path"] as? String)
                })
            #expect(created == "\(dir)/Untitled Folder")
            try await app.asyncTest(
                .PATCH, "/jupyterlite/api/contents/\(created)",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"path":"\#(dir)/out"}"#)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let model = try self.object(res)
                    #expect(model["type"] as? String == "directory")
                })
            #expect(FileManager.default.fileExists(atPath: filesDir + dir + "/out"))
            // A rename out of the caller's folder is refused.
            try await app.asyncTest(
                .PATCH, "/jupyterlite/api/contents/\(dir)/out",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"path":"\#(otherRoot)/setup_a/out"}"#)
                },
                afterResponse: { res in #expect(res.status == .forbidden) })
        }
    }
}
