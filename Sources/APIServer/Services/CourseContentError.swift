// APIServer/Services/CourseContentError.swift
//
// Why `CourseContentService` refused a content item (#2769). The web routes map
// it to `AppError.invalidParameter(name: field, reason: description)`
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
    /// The assignment to attach to is not in the item's course.
    case assignmentNotInCourse
    /// A heading has no actions, so it cannot sit on an assignment's row.
    case headingCannotAttach
    /// An attached item takes its assignment's section and is not moved alone.
    case attachedItemCannotMove

    /// The input field the error is about.
    var field: String {
        switch self {
        case .emptyTitle: return "title"
        case .unknownKind: return "kind"
        case .linkMissingURL, .unsafeLinkURL: return "links"
        case .assignmentNotInCourse, .headingCannotAttach: return "assignmentID"
        case .attachedItemCannotMove: return "courseSectionID"
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
        case .assignmentNotInCourse:
            return "The assignment is not in this item's course."
        case .headingCannotAttach:
            return "A heading cannot be shown on an assignment."
        case .attachedItemCannotMove:
            return "This item is shown on an assignment's row and follows that assignment's section. "
                + "Detach it from its assignment first."
        }
    }
}
