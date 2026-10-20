// APIServer/Views/Pages/InstructorAchievementsPage.swift
//
// GET /instructor/achievements: the course Achievements tab
// (docs/achievement-rewards.md, S4). The course achievements, in the same
// table and templates as the assignment editor; who has earned each one; and
// the built-in rules, read-only, so the course does not grant what students
// earn anyway.

import Core
import Elementary

struct InstructorAchievementsPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    let signalOptions: [AchievementSignalOption]
    let recordDimensionOptions: [RecordDimensionOption]
    let targets: CourseAchievementTargetOptions
    let earned: [CourseAchievementEarnedRow]
    let builtIn: [BuiltInRuleRow]

    var body: some HTML {
        BaseLayout(title: "Achievements", page: page, flash: flash) {
            InstructorTabs(active: .achievements)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its achievements." }
                }
            } else {
                CourseAchievementsSection(
                    courseCode: courseCode, signalOptions: signalOptions,
                    recordDimensionOptions: recordDimensionOptions, targets: targets)
                earnedSection
                builtInSection
            }
            if hasActiveCourse {
                script(.src(page.asset("/achievements-editor-core.js"))) {}
                script(.src(page.asset("/achievements-editor.js"))) {}
            }
        }
    }

    private var earnedSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Earned so far" }
                form(.method(.post), .action("/instructor/achievements/recompute"), .class("form-flush")) {
                    CSRFField(token: page.csrfToken)
                    button(.class("btn action-btn"), .type(.submit)) { "Recompute" }
                }
            }
            p(.class("section-intro")) {
                "A student's course achievements are stored when their result page or account page loads."
            }
            if earned.isEmpty {
                p(.class("empty")) { "No course achievements yet." }
            } else {
                table(.class("results-table")) {
                    thead {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Achievement" }
                            th(.custom(name: "scope", value: "col")) { "Earned by" }
                        }
                    }
                    tbody {
                        for row in earned {
                            tr {
                                td { strong { row.name } }
                                td { EarnersDisclosure(row: row) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var builtInSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) { h2 { "Built in" } }
            p(.class("section-intro")) { "What every student earns in every course, with no setup." }
            table(.class("results-table")) {
                thead {
                    tr {
                        th(.custom(name: "scope", value: "col")) { "Item" }
                        th(.custom(name: "scope", value: "col")) { "Rule" }
                    }
                }
                tbody {
                    for rule in builtIn {
                        tr {
                            td { rule.itemName }
                            td { rule.howEarned }
                        }
                    }
                }
            }
        }
    }
}

/// The course achievements table, which achievements-editor.js fills from
/// GET /instructor/achievements/rows and saves with a PUT to the same URL.
/// The `/instructor` gate admits staff of the active course, and an archived
/// course is never the active course, so a reader of this page may edit it.
private struct CourseAchievementsSection: HTML {
    let courseCode: String
    let signalOptions: [AchievementSignalOption]
    let recordDimensionOptions: [RecordDimensionOption]
    let targets: CourseAchievementTargetOptions

    var body: some HTML {
        section(
            .class("page-section"), .id("achievements-block"),
            .data("url", value: "/instructor/achievements/rows"),
            .data("level", value: AchievementLevel.course.rawValue)
        ) {
            div(.class("page-titlebar")) {
                h2 { "Course achievements" }
                div(.class("toolbar")) {
                    button(.type(.button), .class("btn action-btn"), .id("achievement-add")) { "+ Add Achievement" }
                    span(
                        .id("achievements-status"), .class("upload-status-inline"), .role("status"),
                        .custom(name: "aria-live", value: "polite")
                    ) {}
                }
            }
            p(.class("section-intro")) { "Badges that count a student's work across the assignments in \(courseCode)." }
            AchievementsTable(
                signalOptions: signalOptions, recordDimensionOptions: recordDimensionOptions, courseTargets: targets)
        }
    }
}

/// "2 of 40 students", and the names with the dates under a disclosure.
private struct EarnersDisclosure: HTML {
    let row: CourseAchievementEarnedRow

    var body: some HTML {
        if row.earners.isEmpty {
            row.countText
        } else {
            details {
                summary(.class("disclosure-summary")) {
                    span(.class("accordion-caret"), .ariaHidden) { Icon("i-chevron-right") }
                    row.countText
                }
                ul {
                    for earner in row.earners {
                        li { "\(earner.name) · \(earner.earnedText)" }
                    }
                }
            }
        }
    }
}
