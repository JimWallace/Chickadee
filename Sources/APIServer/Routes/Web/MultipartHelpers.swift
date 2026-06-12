// APIServer/Routes/Web/MultipartHelpers.swift
//
// Multipart form parsing helpers and URL-encoding shared across the
// instructor assignment routes.  Extracted from AssignmentHelpers.swift
// (issue #442) — no behaviour changes.

import Foundation
import Vapor

func urlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

func multipartParts(from req: Request) throws -> [MultipartPart]? {
    guard let contentType = req.headers.contentType,
        contentType.type == "multipart",
        contentType.subType == "form-data",
        let boundary = contentType.parameters["boundary"],
        let body = req.body.data
    else {
        return nil
    }

    let parser = MultipartParser(boundary: boundary)
    var parts: [MultipartPart] = []
    var headers = HTTPHeaders()
    var partBody = ByteBuffer()

    parser.onHeader = { field, value in
        headers.replaceOrAdd(name: field, value: value)
    }
    parser.onBody = { chunk in
        partBody.writeBuffer(&chunk)
    }
    parser.onPartComplete = {
        parts.append(MultipartPart(headers: headers, body: partBody))
        headers = HTTPHeaders()
        partBody = ByteBuffer()
    }

    try parser.execute(body)
    return parts
}

func multipartFiles(named names: [String], from req: Request) throws -> [File]? {
    guard let parts = try multipartParts(from: req) else { return nil }
    let files =
        names
        .flatMap { name in parts.allParts(named: name) }
        .compactMap(File.init(multipart:))
    return files.isEmpty ? nil : files
}

func multipartTextField(named names: [String], from req: Request) throws -> String? {
    guard let parts = try multipartParts(from: req) else { return nil }
    for name in names {
        if let part = parts.firstPart(named: name),
            let value = String(multipart: part)
        {
            return value
        }
    }
    return nil
}
