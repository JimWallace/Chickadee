// APIServer/Services/CourseGroupError.swift
//
// Why a change to a course's groups was refused (docs/lab-groups.md). Each
// description is the sentence the Groups tab shows.

enum CourseGroupError: Error, Sendable, Equatable, CustomStringConvertible {
    case blankName
    case nameTooLong(limit: Int)
    case duplicateGroupName(String)
    case setNotEditable
    case groupNotInSet
    case groupRemoved
    case notEnrolled
    case conflictingRows(usernames: [String])
    case missingColumns
    case unreadableFile
    case emptyFile

    var description: String {
        switch self {
        case .blankName:
            return "Enter a name."
        case .nameTooLong(let limit):
            return "Use a name of at most \(limit) characters."
        case .duplicateGroupName(let name):
            return "This set already has a group named \(name)."
        case .setNotEditable:
            return "This group set comes from LEARN, so change its groups in LEARN."
        case .groupNotInSet:
            return "That group is not in this set."
        case .groupRemoved:
            return "That group was removed."
        case .notEnrolled:
            return "That person is not enrolled in this course."
        case .conflictingRows(let usernames):
            return "The file puts these students in two groups: \(usernames.joined(separator: ", "))."
        case .missingColumns:
            return "The file needs a username column and a group column."
        case .unreadableFile:
            return "The file is not a readable CSV file."
        case .emptyFile:
            return "The file has no rows."
        }
    }
}
