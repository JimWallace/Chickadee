// APIServer/Errors/MCPUploadError.swift
//
// Why a staged MCP upload (docs/mcp-file-uploads.md) was refused. The upload
// route answers with `status` and `reason`; the MCP write tools give
// `toolDetail` to the agent as an invalid-arguments detail.

import Vapor

enum MCPUploadError: AbortError, Equatable, Sendable, CustomStringConvertible {
    /// No live upload has this token or id for this grant. A token or id that
    /// another grant began answers the same, so it tells nothing about them.
    case unknownUpload
    /// The upload expired before it was used.
    case expired
    /// The URL already received a file; an upload URL takes one PUT.
    case alreadyUploaded
    /// `begin_upload` was called but no file has been PUT to the URL yet.
    case notUploadedYet
    /// The upload belongs to another course than the tool call names.
    case wrongCourse
    case tooLarge(maxBytes: Int)
    case empty
    case notUTF8
    /// The grant already holds `limit` uploads that are neither used nor expired.
    case tooManyOpen(limit: Int)
    /// The `uploadID` argument is not an upload id.
    case malformedID(String)

    var status: HTTPResponseStatus {
        switch self {
        case .unknownUpload, .expired: return .notFound
        case .alreadyUploaded, .notUploadedYet, .wrongCourse: return .conflict
        case .tooLarge: return .payloadTooLarge
        case .empty, .notUTF8, .malformedID: return .unprocessableEntity
        case .tooManyOpen: return .tooManyRequests
        }
    }

    var reason: String { toolDetail }

    var description: String { toolDetail }

    var toolDetail: String {
        switch self {
        case .unknownUpload:
            return "No pending upload matches that uploadID or URL for this agent. Call begin_upload for a new one."
        case .expired:
            return "The upload expired before it was used. Call begin_upload and upload the file again."
        case .alreadyUploaded:
            return "This upload URL already received a file. Call begin_upload for another file."
        case .notUploadedYet:
            return "No file has been uploaded to this upload's URL yet. PUT the file's bytes to uploadURL first."
        case .wrongCourse:
            return "The upload was begun for another course. Call begin_upload with this course."
        case .tooLarge(let maxBytes):
            return "The file exceeds the \(maxBytes / (1024 * 1024)) MB upload limit."
        case .empty:
            return "The uploaded file is empty."
        case .notUTF8:
            return "The uploaded file is not valid UTF-8 text (binary files are not yet supported)."
        case .tooManyOpen(let limit):
            return "This agent already holds \(limit) unused uploads. Use or let them expire before beginning another."
        case .malformedID(let id):
            return "uploadID \"\(id)\" is not an upload id returned by begin_upload."
        }
    }
}
