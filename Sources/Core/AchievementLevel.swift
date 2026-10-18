// Core/AchievementLevel.swift
//
// Where an achievement's definition lives (docs/achievement-rewards.md,
// decision 1). The level is not a field of `Achievement`: it is a fact of
// the container. An achievement in a manifest is at the assignment level, one
// on a course row is at the course level, and one in the code registry is at
// the site level. The award ledger stores the level beside each award.

/// Where an achievement's definition lives. The raw value is stored in the
/// award ledger, so the enum is append-only.
public enum AchievementLevel: String, Codable, CaseIterable, Sendable {
    /// In one assignment's manifest (`TestProperties.achievements`).
    case assignment
    /// On one course.
    case course
    /// In code, for every course.
    case site
}
