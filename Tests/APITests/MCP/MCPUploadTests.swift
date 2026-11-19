// Tests/APITests/MCP/MCPUploadTests.swift
//
// Staged MCP uploads (docs/mcp-file-uploads.md): `begin_upload` hands out a
// secret URL, the PUT stores the bytes, and `author_script`, `create_dataset`
// and `add_dataset_version` take the `uploadID`. Covers the happy paths, a
// byte-exact round trip, expiry, use by another grant or in another course,
// the size cap, the UTF-8 rule, the single PUT, single use and the cleanup.

import Core
import Fluent
import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The upload paths write zips, so the suite has a time limit.
@Suite(.serialized, .timeLimit(.minutes(5))) final class MCPUploadTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-mcp-upload")
        // MCP is off in the test config, so `routes(app)` did not mount the
        // upload URL. Mount it here, as `registerMCPRoutes` does.
        try app.register(collection: MCPUploadRoutes())
    }

    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
        "timeLimitSeconds":10,"makefile":null,"submissionMode":"uploadOnly"}
        """

    /// A CSV with a header row, multi-byte text, CRLF line ends and no final
    /// newline: every byte must survive the trip.
    private static let csv = "id,ward,note\r\n1,A,caf\u{E9}\r\n2,B,\u{1F9EC} read\r\n3,A,\"q,uoted\""

    private struct Fixture {
        let courseID: UUID
        let assignment: APIAssignment
    }

    /// Course `code` with the instructor `subject`, the library dataset
    /// `ward-cases` and one assignment.
    private func fixture(code: String = "UPL1", subject: String = mcpTestSubject) async throws -> Fixture {
        let courseID = try await makeTestCourse(on: app, code: code).requireID()
        let existing = try await APIUser.query(on: app.db).filter(\.$username == subject).first()
        let staff: APIUser
        if let existing {
            staff = existing
        } else {
            staff = try await makeTestUser(on: app, username: subject, role: "instructor")
        }
        try await makeTestEnrollment(on: app, userID: staff.requireID(), courseID: courseID)
        _ = try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Ward cases", slug: "ward-cases"),
            upload: .init(filename: "cases.csv", bytes: Data("id,ward\n1,A\n2,B\n".utf8)),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db)
        let setupID = "upl_\(UUID().uuidString.prefix(8))"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: Self.manifest, withNotebook: false, withZip: false)
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(courseID: courseID, assignment: assignment)
    }

    private func context(subject: String = mcpTestSubject, clientID: String? = "agent-a") -> ToolContext {
        ToolContext(
            request: makeTestRequest(on: app), subject: subject, grantedScopes: [.read, .write],
            actingClientID: clientID)
    }

    private func begin(_ code: String = "UPL1", _ context: ToolContext) async throws -> BeginUploadTool.Output {
        try await BeginUploadTool().execute(.init(courseCode: code), context)
    }

    /// The path of an upload URL, for the test client.
    private func path(of output: BeginUploadTool.Output) throws -> String {
        let range = try #require(output.uploadURL.range(of: MCPUploadRoutes.pathPrefix))
        return String(output.uploadURL[range.lowerBound...])
    }

    /// PUTs `bytes` to the upload URL and returns the response status and body.
    private func put(
        _ bytes: Data, to output: BeginUploadTool.Output, token: String? = nil
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        let headers: HTTPHeaders = ["Authorization": "Bearer \(token ?? output.uploadToken)"]
        let path = try path(of: output)
        try await app.asyncTest(.PUT, path, headers: headers, body: ByteBuffer(bytes: bytes)) { res in
            status = res.status
            body = res.body.string
        }
        return (status, body)
    }

    private func refusal(_ operation: () async throws -> Void) async -> String? {
        do {
            try await operation()
            return nil
        } catch let MCPToolError.invalidArguments(detail) {
            return detail
        } catch {
            return "\(error)"
        }
    }

    private func authorSupport(
        _ fx: Fixture, uploadID: String, filename: String = "reads.csv", _ context: ToolContext
    ) async throws -> AuthorScriptTool.Output {
        try await AuthorScriptTool().execute(
            AuthorScriptTool.Input(
                assignmentPublicID: fx.assignment.publicID, filename: filename, content: nil, sourceUrl: nil,
                tier: "support", points: nil, displayName: nil, dependsOn: nil, sectionID: nil,
                timeLimitSeconds: nil, failureDetail: nil, graderOnly: nil, uploadID: uploadID),
            context)
    }

    // MARK: - Happy paths

    @Test func beginReturnsAURLOnThisServerForTheCourse() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let output = try await begin("UPL1", context())
            #expect(output.courseKey == "UPL1")
            #expect(output.method == "PUT")
            #expect(output.maxBytes == MCPUploadService.maxBytes)
            #expect(output.uploadURL.contains(MCPUploadRoutes.pathPrefix))
            #expect(output.curlExample.contains(output.uploadURL))
            #expect(output.curlExample.contains("Authorization: Bearer \(output.uploadToken)"))
            #expect(UUID(uuidString: output.uploadID) != nil)
            // The URL names the upload and holds no secret: logs and request
            // metrics record paths.
            #expect(output.uploadURL.hasSuffix(MCPUploadRoutes.pathPrefix + output.uploadID))
            #expect(!output.uploadURL.contains(output.uploadToken))
            // Only the hash of the token is stored.
            let row = try #require(try await MCPUpload.find(UUID(uuidString: output.uploadID), on: app.db))
            #expect(row.tokenHash == sha256HexDigest(output.uploadToken))
            #expect(row.tokenHash != output.uploadToken)
        }
    }

    @Test func authorScriptStoresTheUploadByteForByteAndUsesItUp() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let ctx = context()
            let output = try await begin("UPL1", ctx)
            let bytes = Data(Self.csv.utf8)
            let (status, body) = try await put(bytes, to: output)
            #expect(status == .ok)
            #expect(body.contains(sha256HexDigest(bytes)))
            #expect(body.contains(output.uploadID))

            let written = try await authorSupport(fx, uploadID: output.uploadID, ctx)
            #expect(written.created)
            #expect(!written.isTest)
            let setup = try #require(try await APITestSetup.find(fx.assignment.testSetupID, on: app.db))
            let stored = try #require(await readScriptFromZip(zipPath: setup.zipPath, filename: "reads.csv"))
            #expect(Data(stored.utf8) == bytes)

            // Single use: the row is gone, and a second write is refused.
            #expect(try await MCPUpload.find(UUID(uuidString: output.uploadID), on: app.db) == nil)
            let again = await refusal { _ = try await self.authorSupport(fx, uploadID: output.uploadID, ctx) }
            #expect(again == MCPUploadError.unknownUpload.toolDetail)
        }
    }

    @Test func createDatasetAndAddVersionTakeAnUpload() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let ctx = context()
            let first = try await begin("UPL1", ctx)
            #expect(try await put(Data(Self.csv.utf8), to: first).0 == .ok)
            let created = try await CreateDatasetTool().execute(
                .init(
                    courseCode: "UPL1", name: "DNA reads", slug: "dna-reads", description: nil, provenance: nil,
                    licence: nil, sourceUrl: nil, note: "first", assignmentPublicID: nil, filename: "reads.csv",
                    uploadID: first.uploadID),
                ctx)
            #expect(created.dataset.versions.first?.filename == "reads.csv")
            #expect(created.dataset.versions.first?.rowCount == 3)

            let second = try await begin("UPL1", ctx)
            let newer = Self.csv + "\r\n4,B,more"
            #expect(try await put(Data(newer.utf8), to: second).0 == .ok)
            let added = try await AddDatasetVersionTool().execute(
                .init(
                    courseCode: "UPL1", slug: "dna-reads", sourceUrl: nil, filename: "reads-v2.csv", note: nil,
                    uploadID: second.uploadID),
                ctx)
            #expect(added.version == 2)
            #expect(try await MCPUpload.query(on: app.db).count() == 0)
        }
    }

    @Test func aDatasetUploadNeedsAFilename() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let ctx = context()
            let output = try await begin("UPL1", ctx)
            #expect(try await put(Data(Self.csv.utf8), to: output).0 == .ok)
            let detail = await refusal {
                _ = try await AddDatasetVersionTool().execute(
                    .init(
                        courseCode: "UPL1", slug: "ward-cases", sourceUrl: nil, filename: nil, note: nil,
                        uploadID: output.uploadID),
                    ctx)
            }
            #expect(detail?.contains("Pass filename with uploadID") == true)
            // A refused write leaves the upload for a retry.
            #expect(try await MCPUpload.find(UUID(uuidString: output.uploadID), on: app.db) != nil)
        }
    }

    @Test func aFailedWriteLeavesTheUploadForARetry() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let ctx = context()
            let output = try await begin("UPL1", ctx)
            // The same bytes as the seeded version 1, which the library refuses.
            #expect(try await put(Data("id,ward\n1,A\n2,B\n".utf8), to: output).0 == .ok)
            let detail = await refusal {
                _ = try await AddDatasetVersionTool().execute(
                    .init(
                        courseCode: "UPL1", slug: "ward-cases", sourceUrl: nil, filename: "cases.csv", note: nil,
                        uploadID: output.uploadID),
                    ctx)
            }
            #expect(detail != nil)
            #expect(try await MCPUpload.find(UUID(uuidString: output.uploadID), on: app.db) != nil)
        }
    }

    // MARK: - Refusals

    @Test func anExpiredUploadIsRefusedAndPurged() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let ctx = context()
            let past = Date().addingTimeInterval(-2 * MCPUploadService.lifetime)
            let token = MCPOAuthRoutes.randomToken()
            let ticket = try await MCPUploadService.begin(
                owner: ctx.uploadOwner, courseID: fx.courseID, token: token, on: app.db, now: past)

            // The PUT is refused once the upload has expired.
            await #expect(throws: MCPUploadError.expired) {
                _ = try await MCPUploadService.receive(
                    id: ticket.id, token: token, bytes: Data("a,b\n".utf8), on: self.app.db)
            }
            // So is a write naming it, even with bytes stored in time.
            _ = try await MCPUploadService.receive(
                id: ticket.id, token: token, bytes: Data("a,b\n1,2\n".utf8), on: app.db, now: past)
            let detail = await refusal { _ = try await self.authorSupport(fx, uploadID: ticket.id.uuidString, ctx) }
            #expect(detail == MCPUploadError.expired.toolDetail)

            // The reaper deletes it.
            try await reapExpiredMCPOAuthRecords(on: app.db, logger: app.logger)
            #expect(try await MCPUpload.find(ticket.id, on: app.db) == nil)
        }
    }

    @Test func anotherGrantCannotUseTheUpload() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await makeTestEnrollment(
                on: app,
                userID: try await makeTestUser(on: app, username: "other_staff", role: "instructor").requireID(),
                courseID: fx.courseID)
            let owner = context(clientID: "agent-a")
            let output = try await begin("UPL1", owner)
            #expect(try await put(Data(Self.csv.utf8), to: output).0 == .ok)

            // Another account in the same course.
            let otherAccount = await refusal {
                _ = try await self.authorSupport(fx, uploadID: output.uploadID, self.context(subject: "other_staff"))
            }
            #expect(otherAccount == MCPUploadError.unknownUpload.toolDetail)
            // The same account through another OAuth client.
            let otherClient = await refusal {
                _ = try await self.authorSupport(fx, uploadID: output.uploadID, self.context(clientID: "agent-b"))
            }
            #expect(otherClient == MCPUploadError.unknownUpload.toolDetail)
            // The same account with a directly minted service token.
            let serviceToken = await refusal {
                _ = try await self.authorSupport(fx, uploadID: output.uploadID, self.context(clientID: nil))
            }
            #expect(serviceToken == MCPUploadError.unknownUpload.toolDetail)

            // None of those used it up: the owner still can.
            _ = try await authorSupport(fx, uploadID: output.uploadID, owner)
        }
    }

    @Test func anUploadIsBoundToItsCourse() async throws {
        try await withApp(app) { _ in
            _ = try await fixture(code: "UPL1")
            let other = try await fixture(code: "UPL2")
            let ctx = context()
            let output = try await begin("UPL1", ctx)
            #expect(try await put(Data(Self.csv.utf8), to: output).0 == .ok)
            let detail = await refusal { _ = try await self.authorSupport(other, uploadID: output.uploadID, ctx) }
            #expect(detail == MCPUploadError.wrongCourse.toolDetail)
        }
    }

    @Test func beginNeedsAnEnrollmentInTheCourse() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            _ = try await makeTestUser(on: app, username: "outsider", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await self.begin("UPL1", self.context(subject: "outsider"))
            }
        }
    }

    @Test func anOversizeFileIsRefused() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let output = try await begin("UPL1", context())
            // The route refuses the body before it is stored.
            let big = Data(repeating: UInt8(ascii: "a"), count: MCPUploadService.maxBytes + 1)
            #expect(try await put(big, to: output).0 == .payloadTooLarge)
            let row = try #require(try await MCPUpload.find(UUID(uuidString: output.uploadID), on: app.db))
            #expect(row.uploadedAt == nil)
            // The service refuses it too, for a body that reaches it.
            #expect(throws: MCPUploadError.tooLarge(maxBytes: MCPUploadService.maxBytes)) {
                try MCPUploadService.validate(big)
            }
            // A file of exactly the cap is accepted.
            let atCap = Data(repeating: UInt8(ascii: "a"), count: MCPUploadService.maxBytes)
            #expect(try await put(atCap, to: output).0 == .ok)
        }
    }

    @Test func aNonUTF8FileIsRefused() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let output = try await begin("UPL1", context())
            let (status, body) = try await put(Data([0x69, 0x64, 0x0A, 0xFF, 0xFE, 0x00]), to: output)
            #expect(status == .unprocessableEntity)
            #expect(body.contains("UTF-8"))
            let empty = try await put(Data(), to: output)
            #expect(empty.0 == .unprocessableEntity)
            // Neither was stored, so the URL still takes a good file.
            #expect(try await put(Data(Self.csv.utf8), to: output).0 == .ok)
        }
    }

    @Test func theURLTakesOnePut() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let output = try await begin("UPL1", context())
            #expect(try await put(Data("a\n".utf8), to: output).0 == .ok)
            #expect(try await put(Data("b\n".utf8), to: output).0 == .conflict)
            // A made-up id answers as unknown.
            let unknown = MCPUploadRoutes.pathPrefix + UUID().uuidString
            try await app.asyncTest(
                .PUT, unknown, headers: ["Authorization": "Bearer \(output.uploadToken)"],
                body: ByteBuffer(string: "x")
            ) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test func thePutNeedsTheUploadToken() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let output = try await begin("UPL1", context())
            // A wrong token answers as an unknown upload and stores nothing.
            #expect(try await put(Data("a\n".utf8), to: output, token: "wrong").0 == .notFound)
            // So does no token at all.
            let path = try path(of: output)
            try await app.asyncTest(.PUT, path, body: ByteBuffer(string: "a\n")) {
                #expect($0.status == .notFound)
            }
            let row = try #require(try await MCPUpload.find(UUID(uuidString: output.uploadID), on: app.db))
            #expect(row.uploadedAt == nil)
            #expect(try await put(Data("a\n".utf8), to: output).0 == .ok)
        }
    }

    @Test func aWriteBeforeThePutIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let ctx = context()
            let output = try await begin("UPL1", ctx)
            let detail = await refusal { _ = try await self.authorSupport(fx, uploadID: output.uploadID, ctx) }
            #expect(detail == MCPUploadError.notUploadedYet.toolDetail)
        }
    }

    @Test func authorScriptTakesExactlyOneSource() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let ctx = context()
            let output = try await begin("UPL1", ctx)
            let detail = await refusal {
                _ = try await AuthorScriptTool().execute(
                    AuthorScriptTool.Input(
                        assignmentPublicID: fx.assignment.publicID, filename: "reads.csv", content: "a,b\n",
                        sourceUrl: nil, tier: "support", points: nil, displayName: nil, dependsOn: nil,
                        sectionID: nil, timeLimitSeconds: nil, failureDetail: nil, graderOnly: nil,
                        uploadID: output.uploadID),
                    ctx)
            }
            #expect(detail?.contains("exactly one of") == true)
        }
    }

    @Test func aGrantHoldsABoundedNumberOfOpenUploads() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let ctx = context()
            for _ in 0..<MCPUploadService.maxOpenPerOwner {
                _ = try await begin("UPL1", ctx)
            }
            let detail = await refusal { _ = try await self.begin("UPL1", ctx) }
            #expect(detail == MCPUploadError.tooManyOpen(limit: MCPUploadService.maxOpenPerOwner).toolDetail)
            // Another grant is not held back by this one.
            _ = try await begin("UPL1", context(clientID: "agent-b"))
            // A service token (no OAuth client) is capped too.
            let service = context(clientID: nil)
            for _ in 0..<MCPUploadService.maxOpenPerOwner {
                _ = try await begin("UPL1", service)
            }
            let serviceDetail = await refusal { _ = try await self.begin("UPL1", service) }
            #expect(serviceDetail == MCPUploadError.tooManyOpen(limit: MCPUploadService.maxOpenPerOwner).toolDetail)
        }
    }
}
