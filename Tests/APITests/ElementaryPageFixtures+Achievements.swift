// Tests/APITests/ElementaryPageFixtures+Achievements.swift
//
// The course Achievements tab (docs/achievement-rewards.md, S4): no active
// course, a course with no earners, and a course with earners.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var achievementPages: [ElementaryPageFixture] {
        [instructorAchievementsPage]
    }

    static var instructorAchievementsPage: ElementaryPageFixture {
        let targets = CourseAchievementTargetOptions(
            sections: [.init(id: "S1", name: "Unit 2")],
            assignments: [.init(publicID: "LAB001", title: "Lab 1"), .init(publicID: "LAB002", title: "Lab 2")],
            achievements: [.init(id: "first_try_perfect", name: "Ace")])
        let earned = [
            CourseAchievementEarnedRow(
                name: "Two labs", earners: [.init(name: "Ada Lovelace", earnedText: "Oct 1, 2026 at 9:00 AM")],
                countText: "1 of 40 students"),
            CourseAchievementEarnedRow(name: "Unit 2 done", earners: [], countText: "0 of 40 students"),
        ]
        func render(hasCourse: Bool = true, earned: [CourseAchievementEarnedRow] = []) -> String {
            InstructorAchievementsPage(
                page: page(currentUser: signedInAdmin), hasActiveCourse: hasCourse, courseCode: "CS135",
                signalOptions: AchievementSignalPresentation.all,
                recordDimensionOptions: RecordDimensionPresentation.all, targets: targets, earned: earned,
                builtIn: WardrobeItem.allCases.map(BuiltInRuleRow.init)
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorAchievementsPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false), render(), render(earned: earned),
            ]
        )
    }
}
