// Tests/APITests/AchievementKindPresentationTests.swift
//
// AchievementKindPresentation is the single source of truth for how the
// editor names achievement kinds: the assignment-edit page renders the kind
// dropdown from it, and achievements-editor.js derives its table labels from
// the rendered options.  The exhaustive switch already makes a missing label
// a compile error; these tests pin the rendered output.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementKindPresentationTests {

    @Test func everyKindHasADistinctOption() {
        let options = AchievementKindPresentation.all
        #expect(options.count == AchievementKind.allCases.count)
        #expect(Set(options.map(\.value)).count == options.count, "raw values must be unique")
        #expect(Set(options.map(\.label)).count == options.count, "labels must be unique")
        for option in options {
            #expect(!option.label.isEmpty)
            #expect(!option.detail.isEmpty)
        }
    }

    @Test func editPageRendersOneOptionPerKind() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "kinds_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "kinds_setup", title: "Kinds", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    for option in AchievementKindPresentation.all {
                        #expect(
                            body.contains(
                                "<option value=\"\(option.value)\" data-label=\"\(option.label)\">"),
                            "edit page must render a kind option for \(option.value)")
                    }
                })
        }
    }
}
