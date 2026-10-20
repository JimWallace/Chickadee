// APIServer/Routes/Web/CourseAchievementTargetOptions.swift
//
// What a course condition on the Achievements tab may count over
// (docs/achievement-rewards.md, S4).

import Core

/// What a course condition may count over: the course's sections, the
/// concepts, and the course's assignments for "Chosen assignments".
struct CourseAchievementTargetOptions: Sendable {
    struct Section: Sendable {
        /// The course section id, as a course condition stores it.
        let id: String
        let name: String
    }

    struct Assignment: Sendable {
        let publicID: String
        let title: String
    }

    /// One assignment-level individual achievement that an
    /// `achievementsEarned` condition may count, by its id.
    struct AchievementChoice: Sendable {
        let id: String
        let name: String
    }

    let sections: [Section]
    /// Each concept, by its `AssignmentConcept` raw value.
    let concepts: [SelectOption]
    let assignments: [Assignment]
    let achievements: [AchievementChoice]

    init(sections: [Section], assignments: [Assignment], achievements: [AchievementChoice] = []) {
        self.sections = sections
        self.concepts = AssignmentConcept.allCases.map {
            SelectOption(value: $0.rawValue, label: $0.displayName, selected: false)
        }
        self.assignments = assignments
        self.achievements = achievements
    }
}
