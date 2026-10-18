// APIServer/Routes/Web/GroupSelectCell.swift
//
// What the Students tab's group select needs for one student
// (docs/lab-groups.md, slice 1). The select posts to
// `POST /instructor/groups/membership`.

/// One group a student can be put in.
struct GroupOption: Codable, Sendable, Equatable {
    let id: String
    let name: String
}

struct GroupSelectCell: Codable, Sendable {
    /// The URL every group select posts to.
    static let action = "/instructor/groups/membership"

    /// The student's user id; it names the select element.
    let userID: String
    let setID: String
    /// The name the hidden label reads ("Group for <name>").
    let personName: String
    /// The current group's id, or "" for no group.
    let groupID: String
    let options: [GroupOption]
}
