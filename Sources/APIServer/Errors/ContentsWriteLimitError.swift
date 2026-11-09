// APIServer/Errors/ContentsWriteLimitError.swift
//
// A refusal by the storage quota on the editor's contents write routes
// (#2926). JupyterLab shows it as a save error. The rate limit answers 429
// from its middleware and throws nothing.

import Vapor

enum ContentsWriteLimitError: AbortError, Equatable {
    /// The save would take the user's own files past the quota.
    case storageQuotaExceeded(quotaBytes: Int)

    var status: HTTPResponseStatus {
        switch self {
        case .storageQuotaExceeded: return .payloadTooLarge
        }
    }

    var reason: String {
        switch self {
        case .storageQuotaExceeded(let quotaBytes):
            let megabytes = quotaBytes / (1024 * 1024)
            return "This save would take your files past the \(megabytes) MB storage limit. "
                + "Clear large cell outputs and save again, or ask your instructor for help."
        }
    }
}
