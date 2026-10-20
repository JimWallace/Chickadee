// APIServer/Views/AchievementConditionRow.swift
//
// One condition row that achievements-editor.js clones per condition. The
// course Achievements tab adds the course condition controls
// (docs/achievement-rewards.md, S4).

import Elementary

struct AchievementConditionRow: HTML {
    let signalOptions: [AchievementSignalOption]
    /// What a course condition may count over; nil on the assignment editor,
    /// which renders no course control.
    var courseTargets: CourseAchievementTargetOptions?

    var body: some HTML {
        div(.class("am-condition")) {
            select(.class("form-input am-cond-signal"), .ariaLabel("Measure")) {
                for signal in signalOptions {
                    option(
                        .value(signal.value), .data("unit", value: signal.unit), .data("scope", value: signal.scopes),
                        .data("levels", value: signal.levels), .data("course-field", value: signal.courseField),
                        .data("ref-control", value: signal.refControl), .data("ref-field", value: signal.refField),
                        .data("ref-label", value: signal.refLabel),
                        .data("ref-placeholder", value: signal.refPlaceholder),
                        .data("ref-replaces-value", value: signal.refReplacesValue ? "true" : "false")
                    ) { signal.label }
                }
            }
            " "
            select(.class("form-input js-am-cond-comparator"), .ariaLabel("Comparison")) {
                option(.value("atLeast")) { "at least" }
                option(.value("atMost")) { "at most" }
                option(.value("equals")) { "exactly" }
            }
            " "
            input(.type(.number), .class("form-input am-cond-value"), .ariaLabel("Value"))
            " "
            span(.class("am-cond-unit")) {}
            " "
            input(.type(.text), .class("form-input am-cond-ref"), .custom(name: "style", value: "display:none"))
            " "
            // Filled by the editor from the live suite sections on the page,
            // so a section added or renamed without a reload shows under its
            // current name.
            select(.class("form-input am-cond-ref"), .custom(name: "style", value: "display:none")) {}
            " "
            if let courseTargets {
                CourseConditionControls(targets: courseTargets)
                " "
            }
            button(
                .type(.button), .class("btn action-btn action-danger am-cond-remove"), .ariaLabel("Remove condition")
            ) {
                "×"
            }
        }
    }
}

/// The course condition's own inputs: the set it counts over, the grade floor
/// of `assignmentsAtGrade` and the achievement id of `achievementsEarned`.
/// The editor shows the floor and the id by the signal's `data-course-field`,
/// and the assignment checklist when the set is "Chosen assignments".
private struct CourseConditionControls: HTML {
    let targets: CourseAchievementTargetOptions

    var body: some HTML {
        select(.class("form-input js-am-cond-target"), .ariaLabel("Counts over")) {
            option(.value("")) { "Every assignment" }
            if !targets.sections.isEmpty {
                optgroup(.label("Course sections")) {
                    for section in targets.sections {
                        option(.value("courseSection:\(section.id)")) { section.name }
                    }
                }
            }
            optgroup(.label("Concepts")) {
                for concept in targets.concepts {
                    option(.value("concept:\(concept.value)")) { concept.label }
                }
            }
            option(.value("assignments:")) { "Chosen assignments" }
        }
        " "
        input(
            .type(.number), .class("form-input js-am-cond-floor"), .ariaLabel("Grade floor (%)"),
            .min(0), .max(100), .placeholder("%"), .custom(name: "style", value: "display:none"))
        " "
        select(
            .class("form-input js-am-cond-achref"), .ariaLabel("Achievement"),
            .custom(name: "style", value: "display:none")
        ) {
            option(.value("")) { "Any achievement" }
            for achievement in targets.achievements {
                option(.value(achievement.id)) { achievement.name }
            }
        }
        // Closed by default, so a course with many assignments does not put
        // a tall list in every condition row.
        details(.class("js-am-cond-assignments"), .custom(name: "style", value: "display:none")) {
            summary(.class("disclosure-summary")) {
                span(.class("accordion-caret"), .ariaHidden) { Icon("i-chevron-right") }
                "Assignments"
            }
            div(.class("checkbox-list")) {
                for assignment in targets.assignments {
                    label(.class("checkbox-row")) {
                        input(.type(.checkbox), .value(assignment.publicID))
                        assignment.title
                    }
                }
            }
        }
    }
}
