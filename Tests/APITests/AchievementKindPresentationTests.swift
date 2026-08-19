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
import VaporTesting

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

    /// Every per-reference fact the editor needs rides on the option, so a new
    /// ref kind cannot render an input that is unlabelled or that serializes
    /// into no field.
    ///
    /// This is the guard the JS-side lookup table did not have. That table
    /// named two ref kinds and answered `"Reference"` for a third, and a `refField`
    /// branch written as `=== "section"` dropped a third kind's value on save —
    /// both compiling, both silent.
    @Test func aReferencingSignalCarriesEveryFactItsInputNeeds() {
        for option in AchievementSignalPresentation.all where !option.refControl.isEmpty {
            #expect(
                !option.refField.isEmpty,
                "\(option.value) shows a reference input that serializes into no ConditionRow field")
            #expect(
                !option.refLabel.isEmpty,
                "\(option.value)'s reference input would have no accessible name")
            #expect(
                ["text", "sections"].contains(option.refControl),
                "\(option.value) asks for a reference control the editor does not build")
        }
        // The complement: a signal with no reference carries no reference facts,
        // so nothing renders an input the condition cannot use.
        for option in AchievementSignalPresentation.all where option.refControl.isEmpty {
            #expect(option.refField.isEmpty, "\(option.value) names a ref field with no input")
        }
    }

    /// A reference field must exist on `ConditionRow`, because the JS writes it
    /// by name — a typo would post a key the decoder drops.
    @Test func everyReferenceFieldExistsOnTheConditionRow() throws {
        let row = ConditionRow(
            signal: "x", comparator: "atLeast", value: 1, testRef: "t", sectionRef: "s")
        let encoded = try JSONEncoder().encode(row)
        let keys = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        ).keys
        for option in AchievementSignalPresentation.all where !option.refField.isEmpty {
            #expect(
                keys.contains(option.refField),
                "`ConditionRow` has no `\(option.refField)` field for \(option.value)")
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
