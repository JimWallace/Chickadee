// APIServer/Views/LeaderboardGroupControl.swift
//
// The lab group a per-group activity's board shows (docs/lab-groups.md,
// slice 3), in the leaderboard's toolbar: a `LabGroupSelect` for staff, who
// read every group's board, and the group's name for a student, who reads
// their own.

import Elementary
import Foundation

struct LeaderboardGroupControl: HTML {
    let scope: LeaderboardGroupScope
    let boardURL: String

    var body: some HTML {
        if scope.options.count > 1 {
            LabGroupSelect(
                id: "board-group", action: boardURL, options: scope.options, selectedID: scope.groupID?.uuidString)
        } else if let name = scope.groupName {
            span(.class("chip")) {
                span(.class("visually-hidden")) { "Lab group: " }
                name
            }
        }
    }
}
