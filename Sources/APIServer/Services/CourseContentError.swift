// APIServer/Services/CourseContentError.swift
//
// Why `CourseContentService` refused a content item (#2769). The web routes map
// it to `WebAssignmentError.invalidParameter(name: field, reason: description)`
// and the MCP tools to `MCPToolError.invalidArguments(detail: description)`, so
// both surfaces give the same reason.

import Core

enum CourseContentError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyTitle
    /// The kind is not a `ContentItemKind`. Before #2769 the web stored it as a
    /// link without a word; MCP already refused it (#2337).
    case unknownKind(String)
    /// A link has a label but no URL.
    case linkMissingURL(label: String)
    /// A link URL is not http(s) or site-relative.
    case unsafeLinkURL(String)

    /// The input field the error is about.
    var field: String {
        switch self {
        case .emptyTitle: return "title"
        case .unknownKind: return "kind"
        case .linkMissingURL, .unsafeLinkURL: return "links"
        }
    }

    var description: String {
        switch self {
        case .emptyTitle:
            return "Title must not be empty."
        case .unknownKind:
            // The same list `MCPEnumProse.parse` names, from one source.
            return "kind must be one of: \(MCPEnumProse<ContentItemKind>.oneOfList)."
        case .linkMissingURL(let label):
            return "The link labelled \"\(label)\" is missing a URL."
        case .unsafeLinkURL(let url):
            return "Link URL \"\(url)\" must be an http(s) or site-relative (/…) URL."
        }
    }
}
