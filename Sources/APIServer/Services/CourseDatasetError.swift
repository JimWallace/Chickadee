// APIServer/Services/CourseDatasetError.swift
//
// Why the course dataset library refused an operation
// (docs/datasets-course-library.md). Each description is user-facing: the web
// panel and the MCP tools that arrive in later slices show it as it is.

import Core

enum CourseDatasetError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSlug(String)
    case slugTaken(String)
    case invalidName
    case invalidFilename(String)
    case notUTF8
    case tooLarge(sizeBytes: Int, limitBytes: Int)
    case notATable(DatasetDictionary.ProfileError)
    case duplicateVersion(of: Int)
    case unknownVersion(Int)
    case dictionary(String)
    case missingGovernance
    case governanceRequiredWhilePublished
    case inUse(by: [String])
    case versionNumberContended
    case datasetGone
    case wrongCourse
    case unreadableManifest
    case unreadableFile(String)
    case notASupportFile(String)
    case fileTaken(String)
    case alreadyAttached(String)
    case notAttached(String)
    case alreadyAtVersion(Int)
    case attachmentIssue(String)
    case fileInUse(String, by: [String])
    case bundledDatasetEmpty(String)
    case bundledVersionMismatch(slug: String, version: Int)

    var description: String {
        switch self {
        case .invalidSlug(let slug):
            return "'\(slug)' is not a valid dataset slug. Use 1 to 64 lowercase letters, digits and "
                + "hyphens, starting and ending with a letter or a digit."
        case .slugTaken(let slug):
            return "This course already has a dataset with the slug '\(slug)'."
        case .invalidName:
            return "A dataset needs a name of 1 to \(CourseDatasetService.maxNameLength) characters."
        case .invalidFilename(let name):
            return "'\(name)' is not a valid dataset filename. Use a bare filename that ends in .csv."
        case .notUTF8:
            return "The file is not UTF-8 text. A library dataset is a CSV file."
        case .tooLarge(let size, let limit):
            return "The file is \(size) bytes. A library dataset version can be at most \(limit) bytes."
        case .notATable(let error):
            return error.description
        case .duplicateVersion(let version):
            return "These bytes are the same as version \(version). Nothing changed, so no version was added."
        case .unknownVersion(let version):
            return "This dataset has no version \(version)."
        case .dictionary(let message):
            return message
        case .missingGovernance:
            return "Add a provenance and a licence before you publish this dataset. "
                + "Students see both on the Data page."
        case .governanceRequiredWhilePublished:
            return "A published dataset must keep its provenance and its licence. Unpublish it first."
        case .inUse(let users):
            return "This dataset is attached to \(users.joined(separator: ", ")). Detach it first."
        case .versionNumberContended:
            return "Other uploads to this dataset took every version number this upload tried. Upload it again."
        case .datasetGone:
            return "This dataset was deleted from the course library."
        case .wrongCourse:
            return "This dataset belongs to another course. Attach a dataset from this assignment's own course."
        case .unreadableManifest:
            return "The assignment's manifest could not be read, so nothing was changed."
        case .unreadableFile(let name):
            return "'\(name)' could not be read from the assignment's files."
        case .notASupportFile(let name):
            return "'\(name)' is a test, a notebook or a grader-only file. Only a support data file can come from "
                + "the course library."
        case .fileTaken(let name):
            return "This assignment already has a file named '\(name)'. Choose another name, or move that file "
                + "to the course library instead."
        case .alreadyAttached(let name):
            return "'\(name)' is already attached from the course library. Update it to another version instead."
        case .notAttached(let name):
            return "'\(name)' was not attached from the course library."
        case .alreadyAtVersion(let version):
            return "The file is already at version \(version)."
        case .attachmentIssue(let message):
            return message
        case .fileInUse(let name, let users):
            return "'\(name)' is used by \(users.joined(separator: ", ")). Remove that use first, or keep the file."
        case .bundledDatasetEmpty(let slug):
            return "The bundle's dataset '\(slug)' has no version."
        case .bundledVersionMismatch(let slug, let version):
            return "The bundle's file for version \(version) of dataset '\(slug)' is not the file the bundle names."
        }
    }
}
