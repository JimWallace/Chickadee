// APIServer/Services/ActivitySessionError.swift
//
// Why a join code was refused (docs/lab-groups.md, slice 2). Each description
// is the sentence the join page shows.

enum ActivitySessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCode
    case sessionClosed
    case notAStudent
    /// Course staff removed the student from this run of the session.
    case removed
    /// Too many wrong codes in `ActivitySessionStore.joinFailureWindow`.
    case tooManyAttempts

    var description: String {
        switch self {
        case .unknownCode: return "That code is not on the screen now."
        case .sessionClosed: return "That session has ended."
        case .notAStudent: return "Only a student of this course can join its sessions."
        case .removed: return "Course staff removed you from this session."
        case .tooManyAttempts: return "Too many wrong codes. Try again later."
        }
    }
}
