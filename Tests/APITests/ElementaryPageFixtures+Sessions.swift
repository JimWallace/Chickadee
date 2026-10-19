// Tests/APITests/ElementaryPageFixtures+Sessions.swift
//
// The pages of per-group activity sessions (docs/lab-groups.md, slice 2): the
// student's join page, the present page with a lab group's session panel, and
// the staff list of who joined, rendered for ElementaryPageGuardTests.

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
                hasStarted: hasStarted, joinCode: isOpen ? "KM7QX" : nil, secondsLeft: 24, joinedCount: 23,
                joinAddress: "chickadee.example.ca/join")
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

    /// Who joined: none yet, an open session with a removed student, and an
    /// ended session read by a TA of an archived course.
    static var sessionAttendancePage: ElementaryPageFixture {
        let rows = [
            SessionAttendeeRow(
                userID: "u1", name: "Ada Lovelace", username: "alovelace", joinedAtText: "Oct 18, 2026 at 2:31 PM",
                isRemoved: false, isOtherNetwork: true),
            SessionAttendeeRow(
                userID: "u2", name: "Alan Turing", username: "aturing", joinedAtText: "Oct 18, 2026 at 2:33 PM",
                isRemoved: true),
        ]
        func render(
            isOpen: Bool, canRemove: Bool, rows: [SessionAttendeeRow], flash: FlashMessages = FlashMessages()
        )
            -> String
        {
            SessionAttendancePage(
                page: page(currentUser: signedInAdmin), flash: flash, assignmentTitle: "Lab 4: sorting",
                groupName: "Lab 101", testSetupID: "ts1", groupID: "g1", isOpen: isOpen, canRemove: canRemove,
                rows: rows
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "SessionAttendancePage",
            archetype: .titlebarPage,
            renders: [
                render(isOpen: true, canRemove: true, rows: []),
                render(
                    isOpen: true, canRemove: true, rows: rows, flash: FlashMessages(success: "Student removed.")),
                render(isOpen: false, canRemove: false, rows: rows),
            ]
        )
    }
}
