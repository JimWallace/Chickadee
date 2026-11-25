// APIServer/Services/CourseContentError.swift
//
// Why `CourseContentService` refused a content item (#2769). The web routes map
// it to `AppError.invalidParameter(name: field, reason: description)`
// and the MCP tools to `MCPToolError.invalidArguments(detail: description)`, so
// both surfaces give the same reason.

import Core

enum CourseContentError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The languages a lecture notebook may declare: those with an editor
    /// kernel, from `LanguageDescriptor`, so a new kernel language is listed
    /// with no edit here.
    static var lectureLanguagesList: String {
        AssignmentLanguage.allCases.filter(LectureNotebookService.hasEditor).map(\.rawValue).sorted()
            .joined(separator: ", ")
    }

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
    /// A lecture notebook names no language, or a value that is not one
    /// (docs/lecture-notebooks.md). There is no default.
    case lectureLanguageRequired(given: String?)
    /// The language has no editor kernel, so a lecture notebook in it could
    /// not open.
    case lectureLanguageHasNoEditor(AssignmentLanguage)
    /// The notebook bytes are not `.ipynb` JSON with a `cells` array.
    case lectureNotebookInvalid
    /// A lecture notebook opens from its own row; it is not shown on an
    /// assignment's row.
    case lectureCannotAttach
    /// A lecture-notebook edit names an item that is not one.
    case notALectureNotebook
    /// An existing item cannot become a lecture notebook: its links and
    /// attachments have nowhere to go. Create a new item instead.
    case cannotConvertToLecture

    /// The input field the error is about.
    var field: String {
        switch self {
        case .emptyTitle: return "title"
        case .unknownKind: return "kind"
        case .linkMissingURL, .unsafeLinkURL: return "links"
        case .assignmentNotInCourse, .headingCannotAttach: return "assignmentID"
        case .attachedItemCannotMove: return "courseSectionID"
        case .lectureLanguageRequired, .lectureLanguageHasNoEditor: return "language"
        case .lectureNotebookInvalid, .notALectureNotebook, .cannotConvertToLecture: return "notebook"
        case .lectureCannotAttach: return "assignmentID"
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
        case .lectureLanguageRequired(let given):
            let known = CourseContentError.lectureLanguagesList
            guard let given else {
                return "A lecture notebook must declare its language, one of: \(known)."
            }
            return "\"\(given)\" is not a lecture notebook language. Use one of: \(known)."
        case .lectureLanguageHasNoEditor(let language):
            return "\(language.displayName) has no in-browser notebook editor, so a lecture notebook in it "
                + "could not open. Use one of: \(CourseContentError.lectureLanguagesList)."
        case .lectureNotebookInvalid:
            return "The notebook must be .ipynb JSON with a \"cells\" array."
        case .lectureCannotAttach:
            return "A lecture notebook opens from its own row and cannot be shown on an assignment."
        case .notALectureNotebook:
            return "This item is not a lecture notebook."
        case .cannotConvertToLecture:
            return "An existing item cannot become a lecture notebook. Create a new item with a notebook instead."
        }
    }
}
