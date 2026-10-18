// APIServer/Models/CourseGroupSource.swift
//
// Where the groups of a group set come from (docs/lab-groups.md, decision 10).
// Only a manual set accepts edits in Chickadee. A synced set is replaced by its
// sweep, so a local edit to it would be lost at the next run.

enum CourseGroupSource: String, Codable, Sendable, CaseIterable {
    /// Made in Chickadee: the Groups tab and the CSV import.
    case manual
    /// A D2L group category, read through Valence.
    case learnGroups
    /// The D2L Sections of the course offering, read through Valence.
    case learnSections
}
