// APIServer/Views/AchievementsTable.swift
//
// The Achievements table and the two templates achievements-editor.js clones,
// shared by the assignment editor and the course Achievements tab
// (docs/achievement-rewards.md, S4), so the two cannot drift.

import Elementary

struct AchievementsTable: HTML {
    let signalOptions: [AchievementSignalOption]
    let recordDimensionOptions: [RecordDimensionOption]
    /// What a course condition may count over; nil on the assignment editor.
    var courseTargets: CourseAchievementTargetOptions?

    var body: some HTML {
        table(.class("results-table"), .id("achievements-table")) {
            thead {
                tr {
                    th { "Name" }
                    th { "Scope" }
                    th { "Earned when" }
                    th {}
                }
            }
            tbody(.class("achievements-body")) {}
        }
        template(.id("achievement-editor-template")) {
            AchievementEditorFields(recordDimensionOptions: recordDimensionOptions, courseLevel: courseTargets != nil)
        }
        // One condition row, cloned into #am-conditions per condition.
        template(.id("achievement-condition-template")) {
            AchievementConditionRow(signalOptions: signalOptions, courseTargets: courseTargets)
        }
    }
}
