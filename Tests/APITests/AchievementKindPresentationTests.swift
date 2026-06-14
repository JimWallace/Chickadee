// Tests/APITests/AchievementKindPresentationTests.swift
//
// AchievementSignalPresentation is the single source of truth for how the
// composable achievements editor names condition signals: the condition-builder
// renders its signal dropdown from it, and achievements-editor.js reads each
// rendered option's data attributes.  The exhaustive switch already makes a
// missing presentation a compile error; these tests pin the rendered output.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementKindPresentationTests {

    @Test func everySignalHasADistinctOption() {
        let options = AchievementSignalPresentation.all
        #expect(options.count == AchievementSignal.allCases.count)
        #expect(Set(options.map(\.value)).count == options.count, "raw values must be unique")
        #expect(Set(options.map(\.label)).count == options.count, "labels must be unique")
        for option in options {
            #expect(!option.label.isEmpty)
            #expect(!option.detail.isEmpty)
        }
    }

    @Test func editPageRendersOneOptionPerSignal() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "signals_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "signals_setup", title: "Signals", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    for option in AchievementSignalPresentation.all {
                        #expect(
                            body.contains("<option value=\"\(option.value)\""),
                            "edit page must render a condition option for \(option.value)")
                    }
                })
        }
    }
}
