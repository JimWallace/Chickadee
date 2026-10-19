// APIServer/Routes/Web/GroupSetPanel.swift
//
// The Groups tab's view of one group set (docs/lab-groups.md, slice 1).

struct GroupSetPanel: Sendable {
    /// One group with its number of enrolled students.
    struct Row: Sendable {
        let id: String
        let name: String
        let memberCount: Int

        /// "1 student" or "24 students".
        var countText: String { memberCount == 1 ? "1 student" : "\(memberCount) students" }
    }

    let id: String
    let name: String
    /// True for a manual set, the only kind Chickadee edits.
    let isManual: Bool
    /// Where the groups come from, or nil for a source this build does not
    /// know.
    var source: CourseGroupSource?
    /// When the LEARN sync last read a synced set, or nil before it has: as
    /// text, and as ISO 8601 for the relative time.
    var lastSyncedText: String?
    var lastSyncedISO: String?
    let groups: [Row]
    /// Enrolled students, and those of them in no group of the set.
    let studentCount: Int
    let ungroupedCount: Int
}
