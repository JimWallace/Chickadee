// Tests/APITests/ElementaryPageFixtures+GroupBoards.swift
//
// The leaderboard page of an activity that runs once per lab group
// (docs/lab-groups.md, slice 3a), rendered for ElementaryPageGuardTests: the
// staff group picker, a student's own group, and a student in no group.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var leaderboardPageWithGroups: ElementaryPageFixture {
        let labA = UUID()
        let options = [
            GroupOption(id: labA.uuidString, name: "Lab 101"), GroupOption(id: UUID().uuidString, name: "Lab 102"),
        ]
        func render(isStaff: Bool, scope: LeaderboardGroupScope) -> String {
            var board = LeaderboardSamples.board(.metric, isStaff: isStaff, empty: scope.groupID == nil)
            board.groupScope = scope
            return LeaderboardPage(page: page(currentUser: signedInAdmin), board: board).render()
        }
        return ElementaryPageFixture(
            typeName: "LeaderboardPage",
            archetype: .plainStudentPage,
            renders: [
                render(
                    isStaff: true,
                    scope: LeaderboardGroupScope(groupID: labA, groupName: "Lab 101", options: options, isLive: true)),
                render(
                    isStaff: false,
                    scope: LeaderboardGroupScope(groupID: labA, groupName: "Lab 101", options: [], isLive: false)),
                render(
                    isStaff: false,
                    scope: LeaderboardGroupScope(groupID: nil, groupName: nil, options: [], isLive: false)),
            ]
        )
    }
}
