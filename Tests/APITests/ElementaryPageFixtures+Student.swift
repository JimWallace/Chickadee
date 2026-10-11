// Tests/APITests/ElementaryPageFixtures+Student.swift
//
// The student-facing pages and the error page: one render per branch.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var studentPages: [ElementaryPageFixture] {
        [errorPage, enrollPage, submitPage, editorResetPage, slipDayConfirmPage]
    }

    static var errorPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "ErrorPage",
            archetype: .plainStudentPage,
            renders: [
                ErrorPage(page: page(), status: 404, title: "Not Found", message: "We couldn't find that page.")
                    .render(),
                ErrorPage(
                    page: page(currentUser: signedInAdmin), status: 500, title: "Internal Server Error",
                    message: "Something went wrong on our end."
                ).render(),
                ErrorPage(page: page(), status: 403, title: "Session refreshed", message: "Reload the page.")
                    .render(),
            ]
        )
    }

    static var enrollPage: ElementaryPageFixture {
        let courses = [
            EnrollCourseRow(id: "c1", code: "CS135", name: "Design", termLabel: "Fall 2026", isEnrolled: true),
            EnrollCourseRow(id: "c2", code: "CS136", name: "", termLabel: nil, isEnrolled: false),
        ]
        return ElementaryPageFixture(
            typeName: "EnrollPage",
            archetype: .plainStudentPage,
            renders: [
                EnrollPage(page: page(currentUser: signedInAdmin), error: nil, courses: courses).render(),
                EnrollPage(page: page(), error: "none_selected", courses: []).render(),
            ]
        )
    }

    static var submitPage: ElementaryPageFixture {
        func render(deadline: Bool, extras: Bool) -> String {
            SubmitPage(
                page: page(currentUser: signedInAdmin), testSetupID: "setup1", assignmentTitle: "Lab 1",
                acceptAttribute: ".ipynb,.py,.zip", acceptHintText: "Python assignment — accepts .ipynb, .py or .zip.",
                errorText: extras ? "That file type is not accepted." : nil,
                requiredFilesText: extras ? "lab1.py, helpers.py" : nil,
                chips: SubmitChips(
                    attemptNumber: 2, deadlineText: deadline ? "Oct 12, 2026, 11:59 PM" : nil,
                    deadlineISO: deadline ? "2026-10-13T03:59:00Z" : nil),
                githubSubmitURL: extras ? "/testsetups/setup1/github" : nil,
                aiFeedbackNotice: extras
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "SubmitPage",
            archetype: .plainStudentPage,
            renders: [render(deadline: false, extras: false), render(deadline: true, extras: true)]
        )
    }

    static var editorResetPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "EditorResetPage",
            archetype: .plainStudentPage,
            renders: [
                EditorResetPage(page: page(currentUser: signedInAdmin), done: false, next: "/testsetups/s1/notebook")
                    .render(),
                EditorResetPage(page: page(currentUser: signedInAdmin), done: true, next: "/").render(),
            ]
        )
    }

    static var slipDayConfirmPage: ElementaryPageFixture {
        func render(stacked: Bool) -> String {
            SlipDayConfirmPage(
                page: page(currentUser: signedInAdmin), testSetupID: "setup1", assignmentTitle: "Lab 1",
                courseCode: "CS135", isStacked: stacked, heldDeadlineText: "Oct 12, 2026, 11:59 PM",
                newDeadlineText: "Oct 13, 2026, 11:59 PM", balance: 2, totalBudget: 3, remainingAfter: 1,
                extensionHours: 24
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "SlipDayConfirmPage",
            archetype: .plainStudentPage,
            renders: [render(stacked: false), render(stacked: true)]
        )
    }
}
