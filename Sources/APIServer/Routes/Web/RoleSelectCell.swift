// Sources/APIServer/Routes/Web/RoleSelectCell.swift

/// One person's course-role select on a roster row, rendered by
/// `_role-select.leaf`. The instructor roster (students and staff) and the
/// admin course page share it, so the three option labels live in one place.
struct RoleSelectCell: Codable {
    /// The person's user id; it names the select element.
    let userID: String
    /// The URL that the form POSTs the new role to.
    let action: String
    /// The name the hidden label reads ("Role for <name>").
    let personName: String
    /// The current `CourseRole` raw value.
    let role: String
}
