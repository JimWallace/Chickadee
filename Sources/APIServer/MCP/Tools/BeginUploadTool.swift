// APIServer/MCP/Tools/BeginUploadTool.swift
//
// Write tool: begin a staged file upload (docs/mcp-file-uploads.md). It returns
// an upload URL on this server and a secret, single-use upload token. The agent
// PUTs a local file's bytes there from its shell (`curl -T`, with the token as
// a bearer header), then passes the returned `uploadID` to
// `author_script`, `create_dataset` or `add_dataset_version` in place of
// `content` or `sourceUrl`. A large file thus reaches the server byte for
// byte, and the agent never has to generate it as tokens.
//
// content:write, TA and above in the course, the same floor as the tools that
// use an upload. The upload belongs to this grant and this course only.

import Core
import Fluent
import Foundation
import Vapor

struct BeginUploadTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
    }

    struct Output: Encodable, Sendable {
        let courseKey: String
        let courseTerm: String?
        let uploadID: String
        /// The URL to PUT the file to. It names the upload and holds no secret.
        let uploadURL: String
        /// The secret the PUT presents as `Authorization: Bearer`. It is the
        /// credential: do not share it.
        let uploadToken: String
        let method: String
        let maxBytes: Int
        /// ISO 8601. The upload must be PUT and used before this.
        let expiresAt: String
        /// A shell command that uploads a file named FILE.
        let curlExample: String
    }

    static let name = "begin_upload"
    static let description =
        "Begin a staged upload of a local file, for a file too large to pass inline as content "
        + "(e.g. a CSV dataset or a support module of hundreds of KB). Returns uploadID, an uploadURL on "
        + "this server and a secret, single-use uploadToken. PUT the file's raw bytes there from a shell, "
        + "with the token as a bearer header: curl -sS -T FILE -H \"Authorization: Bearer <uploadToken>\" "
        + "\"<uploadURL>\" (curlExample has it filled in). The response gives the stored "
        + "sizeBytes and sha256, to check against the local file. Then pass uploadID, in place of "
        + "content or sourceUrl, to author_script, create_dataset or add_dataset_version in the same "
        + "course. The file must be UTF-8 text of at most \(MCPUploadService.maxBytesText) (a dataset "
        + "must also be a CSV with a header row). The upload belongs to this agent's grant and this "
        + "course only, is deleted once a write uses it (a write that fails leaves it for a retry), and "
        + "expires \(Int(MCPUploadService.lifetime / 60)) minutes after this call. An agent holds at "
        + "most \(MCPUploadService.maxOpenPerOwner) unused uploads at once."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: ["courseCode": MCPSchema.courseCode], required: ["courseCode"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "courseKey": MCPSchema.courseKeyOutput, "courseTerm": MCPSchema.courseTermOutput,
            "uploadID": MCPSchema.string, "uploadURL": MCPSchema.string, "uploadToken": MCPSchema.string,
            "method": MCPSchema.string,
            "maxBytes": MCPSchema.integer, "expiresAt": MCPSchema.string, "curlExample": MCPSchema.string,
        ],
        required: [
            "courseKey", "uploadID", "uploadURL", "uploadToken", "method", "maxBytes", "expiresAt", "curlExample",
        ],
        additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(
            code: input.courseCode, context: context, atLeast: CourseRoleFloor.manageCourseDatasets)
        // A 256-bit secret, minted as the OAuth codes are.
        let token = MCPOAuthRoutes.randomToken()
        let ticket = try await mcpUploadCall {
            try await MCPUploadService.begin(
                owner: context.uploadOwner, courseID: try course.requireID(), token: token, on: context.mainDB)
        }
        let url = Self.origin(of: context.request) + MCPUploadRoutes.pathPrefix + ticket.id.uuidString
        return Output(
            courseKey: course.urlKey, courseTerm: course.term?.displayName,
            uploadID: ticket.id.uuidString, uploadURL: url, uploadToken: token, method: "PUT",
            maxBytes: MCPUploadService.maxBytes, expiresAt: iso8601String(ticket.expiresAt),
            curlExample: "curl -sS -T FILE -H \"Authorization: Bearer \(token)\" \"\(url)\"")
    }

    /// The origin the agent reaches this server at: the MCP metadata origin
    /// when one is configured, else the request's own host.
    static func origin(of request: Request) -> String {
        let config = request.application.appConfig
        if let endpoints = MCPEndpoints.resolve(mcp: config.mcp, security: config.security) {
            return endpoints.metadataOrigin
        }
        let host = request.headers.first(name: .host) ?? "localhost"
        return "http://\(host)"
    }
}

// MARK: - Using an upload from a write tool

extension ToolContext {
    /// The grant an upload began on this call belongs to.
    var uploadOwner: MCPUploadService.Owner {
        MCPUploadService.Owner(subject: subject, clientID: actingClientID)
    }
}

/// The staged upload `uploadID`, for a write in `courseID`. Not consumed:
/// call `consumeMCPUpload` once the write succeeds.
func loadMCPUpload(
    _ uploadID: String, courseID: UUID, context: ToolContext
) async throws
    -> MCPUploadService.Staged
{
    try await mcpUploadCall {
        try await MCPUploadService.load(uploadID, owner: context.uploadOwner, courseID: courseID, on: context.mainDB)
    }
}

/// Deletes a used upload, so it cannot be used again. The write it fed has
/// already committed, so a failed delete is logged, not thrown: the agent
/// would otherwise retry a write that succeeded. The row still expires.
func consumeMCPUpload(_ staged: MCPUploadService.Staged, context: ToolContext) async {
    do {
        try await MCPUploadService.consume(staged.id, on: context.mainDB)
    } catch {
        context.logger.warning("mcp.upload.consume_failed id=\(staged.id) error=\(String(reflecting: error))")
    }
}

/// Runs an upload operation and gives a refusal to the agent as an
/// invalid-arguments detail.
func mcpUploadCall<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as MCPUploadError {
        throw MCPToolError.invalidArguments(detail: error.toolDetail)
    }
}
