// APIServer/Utilities/JupyterContentsModel.swift
//
// One entry of the Jupyter contents API, as `JupyterLiteContentsRoutes` serves
// it: a file, a notebook or a directory. The route used to build this fixed
// shape twice as `[String: Any]` (#2308).

import Foundation

struct JupyterContentsModel: Encodable {
    /// The `content` key of a model.
    enum Content {
        /// `null`: a listing entry, or a request without `?content=1`.
        case none
        /// A text file.
        case text(String)
        /// A binary file, already base64-encoded.
        case base64(String)
        /// A directory's children.
        case children([JupyterContentsModel])
        /// A JSON file's own bytes, already checked to parse. They are written
        /// into the response as they are, so a large notebook is not decoded
        /// and encoded again on every request.
        case json(Data)
    }

    let name: String
    let path: String
    let lastModified: String
    let created: String
    let content: Content
    let format: String
    let mimetype: String
    let size: Int
    let writable: Bool
    let type: String

    private enum CodingKeys: String, CodingKey {
        case name, path, created, format, mimetype, size, writable, type, content
        case lastModified = "last_modified"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(created, forKey: .created)
        try container.encode(format, forKey: .format)
        try container.encode(mimetype, forKey: .mimetype)
        try container.encode(size, forKey: .size)
        try container.encode(writable, forKey: .writable)
        try container.encode(type, forKey: .type)
        switch content {
        case .none: try container.encodeNil(forKey: .content)
        case .text(let text), .base64(let text): try container.encode(text, forKey: .content)
        case .children(let children): try container.encode(children, forKey: .content)
        case .json: break  // Added by `jsonData()`.
        }
    }

    /// The model as JSON. A `.json` content is appended as the last key.
    func jsonData() throws -> Data {
        var data = try JSONEncoder().encode(self)
        guard case .json(let raw) = content else { return data }
        // The encoder writes an object, so the last byte is its closing brace.
        data.removeLast()
        data.append(contentsOf: Array(#","content":"#.utf8))
        data.append(raw)
        data.append(UInt8(ascii: "}"))
        return data
    }

    /// `data` as `.json` content when it is a JSON object or array in UTF-8,
    /// else nil. A leading UTF-8 byte-order mark is dropped.
    static func jsonContent(_ data: Data) -> Content? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        // Valid UTF-8 JSON has no NUL byte; UTF-16 and UTF-32 JSON, which
        // JSONSerialization also reads, have many and cannot be spliced.
        guard !bytes.contains(0),
            let object = try? JSONSerialization.jsonObject(with: bytes),
            object is [Any] || object is [String: Any]
        else { return nil }
        return .json(bytes)
    }
}
