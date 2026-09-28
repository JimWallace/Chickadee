// APIServer/LTI/LTIMember.swift
//
// One member of an NRPS membership list. Only the fields the roster check
// reads are decoded; a platform may send many more.

import Foundation

struct LTIMember: Codable, Equatable, Sendable {
    /// The member's LTI subject: the same value as the `sub` of their launch.
    let userID: String
    let roles: [String]?
    /// "Active", "Inactive" or "Deleted". Absent means Active.
    let status: String?
    /// The student number, when the platform sends it.
    let sourcedID: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case roles, status
        case sourcedID = "lis_person_sourcedid"
    }

    var isActive: Bool { status == nil || status == "Active" }
}
