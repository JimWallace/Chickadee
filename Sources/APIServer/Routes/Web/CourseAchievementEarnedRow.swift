// APIServer/Routes/Web/CourseAchievementEarnedRow.swift
//
// One row of "Earned so far" on the course Achievements tab
// (docs/achievement-rewards.md, S4).

/// One course achievement and the students who have earned it.
struct CourseAchievementEarnedRow: Sendable {
    struct Earner: Sendable {
        let name: String
        let earnedText: String
    }

    let name: String
    let earners: [Earner]
    /// "2 of 40 students".
    let countText: String
}
