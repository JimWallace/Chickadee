// APIServer/Services/ActivitySessionError.swift
//
// Why a join code was refused (docs/lab-groups.md, slice 2). Each description
// is the sentence the join page shows.

enum ActivitySessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCode
    case sessionClosed
    case notAStudent

    var description: String {
        switch self {
        case .unknownCode: return "No session has that code, so check it against the screen."
        case .sessionClosed: return "That session has ended."
        case .notAStudent: return "Only a student of this course can join its sessions."
        }
    }
}
