// Tests/APITests/ElementaryPageFixtures+History.swift
//
// The submission history, diff and result pages (the "History" group of the
// Leaf-to-Elementary migration), rendered for ElementaryPageGuardTests.

import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var historyPages: [ElementaryPageFixture] {
        [adminEnrollCSVResultPage]
    }

    static var adminEnrollCSVResultPage: ElementaryPageFixture {
        func render(preEnrolled: Int, rejected: [String]) -> String {
            AdminEnrollCSVResultPage(
                page: page(currentUser: signedInAdmin), courseCode: "CS135", courseName: "Design",
                result: EnrollUsernamesResult(
                    enrolledCount: 3, preEnrolledCount: preEnrolled, alreadyEnrolledCount: 1,
                    rejectedUsernames: rejected),
                returnURL: "/instructor"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminEnrollCSVResultPage",
            archetype: .titlebarPage,
            renders: [
                render(preEnrolled: 2, rejected: ["bad;name"]),
                render(preEnrolled: 0, rejected: []),
            ]
        )
    }
}
