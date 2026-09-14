// APIServer/Helpers/TemporaryZipResponse.swift
//
// Streaming a zip that was built into a temp file for one response, and the
// filename sanitizer every zip download names itself with. Shared by the
// course bundle export, the account data export, and the per-assignment
// submissions download so the three cannot drift on the one subtle point:
// WHEN the temp file may be deleted.

import Vapor

/// Streams `zipPath` as an attachment named `downloadName` and deletes the
/// file once the body has been sent.
///
/// The response body streams AFTER the handler returns, so the temp zip must
/// outlive the handler: a `defer` in the caller fires before the first byte
/// is read. The file is removed in `asyncStreamFile`'s completion hook
/// instead. A caller that throws before this returns still owns the cleanup
/// for the no-stream path.
func streamTemporaryZip(
    req: Request, zipPath: String, downloadName: String
) async throws -> Response {
    let response = try await req.fileio.asyncStreamFile(at: zipPath) { _ in
        try? FileManager.default.removeItem(atPath: zipPath)
    }
    response.headers.replaceOrAdd(name: .contentType, value: "application/zip")
    response.headers.replaceOrAdd(
        name: .contentDisposition,
        value: "attachment; filename=\"\(downloadName)\"")
    return response
}

/// Restricts a name to header- and path-safe ASCII for a download filename
/// or an in-zip directory; anything else becomes "-". Never empty.
func sanitizedDownloadComponent(_ raw: String) -> String {
    let mapped = raw.map { ch -> Character in
        if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_") {
            return ch
        }
        return "-"
    }
    let cleaned = String(mapped)
    return cleaned.isEmpty ? "user" : cleaned
}
