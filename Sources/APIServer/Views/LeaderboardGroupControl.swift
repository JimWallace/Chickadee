// APIServer/Views/LeaderboardGroupControl.swift
//
// The lab group a per-group activity's board shows (docs/lab-groups.md,
// slice 3), in the leaderboard's toolbar: a select for staff, who read every
// group's board, and the group's name for a student, who reads their own.

import Elementary
import Foundation

struct LeaderboardGroupControl: HTML {
    let scope: LeaderboardGroupScope
    let boardURL: String

    var body: some HTML {
        if scope.options.count > 1 {
            form(.method(.get), .action(boardURL), .class("inline-form form-flush")) {
                label(.class("visually-hidden"), .for("board-group")) { "Lab group" }
                select(.id("board-group"), .name("group"), .class("form-input"), .dataFlag("ck-submit-on-change")) {
                    for choice in scope.options {
                        option(.value(choice.id)) { choice.name }
                            .attributes(.selected, when: choice.id == scope.groupID?.uuidString)
                    }
                }
            }
        } else if let name = scope.groupName {
            span(.class("chip")) { name }
        }
    }
}
