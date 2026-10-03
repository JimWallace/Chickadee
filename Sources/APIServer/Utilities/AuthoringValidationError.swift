// APIServer/Utilities/AuthoringValidationError.swift
//
// The rules an authored assignment can break, one case per rule (#1929).

import Core
import Foundation

/// A rule that authored assignment content breaks.
///
/// The authoring validators used to throw `Abort(.unprocessableEntity,
/// reason:)` with a hand-written sentence at each site, which made them
/// import Vapor for one type and left no way to ask which rule failed except
/// by matching text. Each case names one rule; `description` is the sentence
/// the validator used to write, word for word, so a page or an MCP agent
/// reads the same message as before. The `AbortError` conformance (status
/// 422) lives beside the server code in `AuthoringValidationError+Abort.swift`,
/// so this file stays free of Vapor.
///
/// Cases are added one validator at a time; `NotebookCheckValidator` is the
/// first.
enum AuthoringValidationError: Error, Equatable, Sendable {
    /// A notebook check's id is not a valid filename fragment.
    case invalidNotebookCheckID(String)
    /// Two notebook checks share an id.
    case duplicateNotebookCheckID(String)
    /// A notebook check has negative points.
    case negativeNotebookCheckPoints(checkID: String)
    /// A notebook check would generate a file that a hand-written script
    /// already uses.
    case notebookCheckCollidesWithHandWrittenFile(checkID: String, filename: String)
    /// A notebook check would generate a file that a pattern family generates.
    case notebookCheckCollidesWithFamilyFile(checkID: String, filename: String)
    /// Two notebook checks would generate the same file.
    case notebookCheckCollidesWithCheckFile(checkID: String, filename: String)
    /// A kernel language cannot render this notebook-check kind.
    case notebookCheckKindUnsupported(
        checkID: String, kind: NotebookCheckKind, language: String,
        supportedKinds: [String], handWrittenExtension: String)
    /// An upload-only language has no notebook workflow, so no kind is
    /// available.
    case notebookCheckKindUnavailable(
        checkID: String, kind: NotebookCheckKind, language: AssignmentLanguage,
        reason: String, handWrittenExtension: String)
    /// A notebook check asks for regex matching in a language whose pattern
    /// syntax is not PCRE.
    case notebookCheckRegexUnsupported(
        checkID: String, kind: NotebookCheckKind, language: String, reason: String)
}

extension AuthoringValidationError: CustomStringConvertible, LocalizedError {
    var description: String {
        switch self {
        case .invalidNotebookCheckID(let id):
            return "Notebook check id '\(id)' must contain only letters, digits, and underscore"
        case .duplicateNotebookCheckID(let id):
            return "Duplicate notebook check id '\(id)'"
        case .negativeNotebookCheckPoints(let checkID):
            return "Notebook check '\(checkID)': points must be non-negative"
        case .notebookCheckCollidesWithHandWrittenFile(let checkID, let filename):
            return
                "Notebook check '\(checkID)' would generate '\(filename)', but a hand-written file with that name already exists. Rename the file or change the check id."
        case .notebookCheckCollidesWithFamilyFile(let checkID, let filename):
            return
                "Notebook check '\(checkID)' would generate '\(filename)', which collides with a pattern family's generated filename. Change the check id."
        case .notebookCheckCollidesWithCheckFile(let checkID, let filename):
            return
                "Notebook check '\(checkID)' would generate '\(filename)', which collides with another check's generated file. Change the check id."
        case .notebookCheckKindUnsupported(
            let checkID, let kind, let language, let supportedKinds, let handWrittenExtension):
            return "Notebook check '\(checkID)' (\(kind.rawValue)) is not supported for "
                + "\(language) assignments — supported kinds are: \(supportedKinds.joined(separator: ", ")). "
                + "Express this check as a hand-written \(handWrittenExtension) test for now."
        case .notebookCheckKindUnavailable(
            let checkID, let kind, let language, let reason, let handWrittenExtension):
            return "Notebook check '\(checkID)' (\(kind.rawValue)) is not available for "
                + "\(language.displayName) assignments: \(reason) Use a pattern family or a "
                + "hand-written \(handWrittenExtension) test instead."
        case .notebookCheckRegexUnsupported(let checkID, let kind, let language, let reason):
            return "Notebook check '\(checkID)' (\(kind.rawValue)) uses regex matching, "
                + "which is not available for \(language) assignments: \(reason)"
        }
    }

    var errorDescription: String? { description }
}
