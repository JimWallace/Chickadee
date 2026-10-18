// Tests/APITests/ElementaryPageFixtures+Sessions.swift
//
// The pages of per-group activity sessions (docs/lab-groups.md, slice 2): the
// student's join page, and the present page with a lab group's session panel,
// rendered for ElementaryPageGuardTests.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var joinSessionPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "JoinSessionPage",
            archetype: .plainStudentPage,
            renders: [
                JoinSessionPage(page: page(currentUser: signedInAdmin)).render(),
                JoinSessionPage(
                    page: page(currentUser: signedInAdmin), error: ActivitySessionError.unknownCode.description,
                    code: "QQQQQ"
                ).render(),
            ]
        )
    }

    /// The present page of a per-group activity: a session not started, one
    /// open with its code on the wall, and one ended.
    static var leaderboardPresentPageWithSession: ElementaryPageFixture {
        let groups = [GroupOption(id: "g1", name: "Lab 101"), GroupOption(id: "g2", name: "Lab 102")]
        func panel(isOpen: Bool, hasStarted: Bool) -> GroupSessionPanel {
            GroupSessionPanel(
                testSetupID: "ts1", groups: groups, selectedGroupID: "g1", groupName: "Lab 101", isOpen: isOpen,
                hasStarted: hasStarted, joinCode: isOpen ? "KM7QX" : nil, joinAddress: "chickadee.example.ca/join")
        }
        let board = LeaderboardSamples.present(places: 5)
        return ElementaryPageFixture(
            typeName: "LeaderboardPresentPage",
            archetype: .fullBleedApp,
            renders: [
                (false, false), (true, true), (false, true),
            ].map { isOpen, hasStarted in
                LeaderboardPresentPage(
                    page: page(), board: board, groupSession: panel(isOpen: isOpen, hasStarted: hasStarted)
                ).render()
            }
        )
    }
}
