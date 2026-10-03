// APIServer/Routes/Web/FileResponseHelpers.swift
//
// The response a file download route sends: an attachment with a content
// type read from the filename. Split from TestSetupZipHelpers.swift when that
// file moved to Helpers/ (#1726), because a `Response` is a route's concern.

import Core
import Foundation
import Vapor

func buildFileResponse(data: Data, filename: String) -> Response {
    var headers = HTTPHeaders()
    headers.contentType = contentType(for: filename)
    headers.add(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}

func contentType(for filename: String) -> HTTPMediaType {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    switch ext {
    case "ipynb", "json":
        return .json
    case "sh", "bash", "zsh", "rb", "pl", "js", "php", "txt", "md", "csv":
        return .plainText
    default:
        // Every assignment language's own extension is text, from the one
        // table — hand-listing them here is what served `.lua` as
        // octet-stream, offering a download prompt instead of displaying it.
        return AssignmentLanguage(scriptExtension: ext) != nil
            ? .plainText
            : HTTPMediaType(type: "application", subType: "octet-stream")
    }
}
