// APIServer/Views/AchievementEditorFields.swift
//
// The inline editor fields that achievements-editor.js clones beneath the
// achievement being edited, on the assignment editor and on the course
// Achievements tab (docs/achievement-rewards.md, S4).

import Elementary

/// The inline achievement editor. Fields show and hide by scope.
struct AchievementEditorFields: HTML {
    let recordDimensionOptions: [RecordDimensionOption]
    /// The course editor offers only the individual scope
    /// (docs/achievement-rewards.md, S3). The other fields stay in the
    /// template, hidden by scope, because the editor reads them by id.
    var courseLevel = false

    var body: some HTML {
        label(.class("form-label field-gap")) {
            "Name "
            input(.type(.text), .class("form-input"), .id("am-name"), .placeholder("e.g. 80% Mastery"))
            " "
        }
        " "
        label(.class("form-label field-gap")) {
            "Description (optional) "
            input(
                .type(.text), .class("form-input"), .id("am-detail"),
                .placeholder("Shown to students - how to earn this."))
            " "
        }
        " "
        label(.class("form-label field-gap")) {
            "Awarded to "
            select(.class("form-input"), .id("am-scope")) {
                option(.value("individual")) { "This student" }
                if !courseLevel {
                    option(.value("classWide")) { "The class together" }
                    option(.value("record")) { "Class record (one holder)" }
                }
            }
            " "
        }
        // The signal options come from AchievementSignalPresentation; the
        // editor clones the condition row per condition.
        div(.class("js-am-scope-field"), .data("scope", value: "individual classWide")) {
            div(.class("subhead-label")) {
                "Earned when "
                select(.class("form-input form-input--inline"), .id("am-match")) {
                    option(.value("all")) { "all" }
                    option(.value("any")) { "any" }
                }
                " of these conditions hold:"
            }
            div(.id("am-conditions"), .class("am-conditions")) {}
            button(.type(.button), .class("btn action-btn"), .id("am-add-condition")) { "+ Add condition" }
        }
        label(.class("form-label field-gap js-am-scope-field"), .data("scope", value: "classWide")) {
            "Class share ≥ (%) "
            input(.type(.number), .class("form-input"), .id("am-classPercent"), .min(0), .max(100))
            " "
        }
        " "
        label(.class("form-label field-gap js-am-scope-field"), .data("scope", value: "classWide")) {
            "Bonus points "
            input(.type(.number), .class("form-input"), .id("am-points"), .min(0))
            " "
        }
        " "
        label(.class("form-label field-gap js-am-scope-field"), .data("scope", value: "record")) {
            "Ranked by "
            select(.class("form-input"), .id("am-recordDimension")) {
                for dimension in recordDimensionOptions {
                    option(.value(dimension.value)) { dimension.label }
                }
            }
            " "
        }
    }
}
