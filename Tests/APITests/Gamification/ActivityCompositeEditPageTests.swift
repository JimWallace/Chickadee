// Tests/APITests/Gamification/ActivityCompositeEditPageTests.swift
//
// The edit page's class-composite settings (docs/class-composite.md, slice 2):
// the detail grid and roster line, the form's POST, the structure lock that a
// disabled input carries, and the projector-only leaderboard.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivityCompositeEditPageTests {

    private func compositeManifest(_ spec: CompositeSpec = .starter) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.sh")],
            language: .python,
            activity: ClassActivity(kind: .classComposite, composite: spec))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func staff(on app: Application) async throws -> String {
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    private func stored(_ setupID: String, on app: Application) async throws -> ClassActivity? {
        try await APITestSetup.find(setupID, on: app.db)?.decodedManifest()?.activity
    }

    private func post(
        _ fields: [String: String], to path: String, csrf: String, cookie: String, on app: Application
    ) async throws -> String {
        var location = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(fields.merging(["_csrf": csrf]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location) ?? ""
            })
        return location
    }

    @Test func thePageShowsTheSettingsAndTheRosterLine() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_cc1", manifest: try compositeManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cc1", title: "Class GPU", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("8 columns × 6 rows (48 slots)"))
                    #expect(html.contains("8 × 8 px, 1 frame, RGB"))
                    #expect(html.contains("Centre out"))
                    #expect(html.contains("Roster: "))
                    #expect(html.contains("Change composite settings"))
                    #expect(html.contains("name=\"cols\""))
                    #expect(!html.contains("name=\"count\""), "a grid compositor shows no slot count")
                    // The composite is for the projector: no visibility toggle.
                    #expect(!html.contains("Save leaderboard setting"))
                })
        }
    }

    @Test func theRosterLineStatesTheShareOfEnrolledStudents() {
        #expect(CompositeEditFacts.rosterLine(slots: 48, enrolledStudents: 62) == "Roster: 62. Slots: 48 (77%).")
        #expect(CompositeEditFacts.rosterLine(slots: 48, enrolledStudents: 0) == "Roster: 0. Slots: 48.")
    }

    @Test func otherKindsShowNoCompositeSettings() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            let props = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "m.sh")], language: nil,
                activity: ClassActivity(kind: .bestMetric))
            let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
            try await wrInsertSetup(id: "setup_cc2", manifest: manifest, on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cc2", title: "Metric Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(!res.body.string.contains("Change composite settings"))
                    #expect(res.body.string.contains("Save leaderboard setting"))
                })
        }
    }

    @Test func thePostSavesTheSettings() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_cc3", manifest: try compositeManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cc3", title: "Class GPU", isOpen: true, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)

            let location = try await post(
                [
                    "compositor": "tile", "cols": "4", "rows": "3", "w": "16", "h": "16", "frames": "30",
                    "format": "gray8", "dealOrder": "rowMajor", "frameRate": "24", "emptySlots": "reference",
                ],
                to: "/instructor/\(assignment.publicID)/activity/composite", csrf: csrf, cookie: cookie, on: app)
            #expect(location.contains("notice="))
            let composite = try #require(try await stored("setup_cc3", on: app)?.composite)
            #expect(composite.layout == .grid(columns: 4, rows: 3))
            #expect(
                composite.contribution == CompositeContributionShape(width: 16, height: 16, frames: 30, format: .gray8))
            #expect(composite.dealOrder == .rowMajor)
            #expect(composite.frameRate == 24)
            #expect(!composite.showFailed, "an unchecked box is posted as absent")
            #expect(composite.emptySlots == .reference)
        }
    }

    /// A compositor change between a grid and a count keeps every slot; the
    /// next render shows the fields for the new shape.
    @Test func aCompositorChangeAcrossShapesKeepsTheSlots() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_cc4", manifest: try compositeManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cc4", title: "Cine Loop", isOpen: true, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)

            _ = try await post(
                ["compositor": "sequence", "cols": "8", "rows": "6", "frameRate": "12", "showFailed": "on"],
                to: "/instructor/\(assignment.publicID)/activity/composite", csrf: csrf, cookie: cookie, on: app)
            let composite = try #require(try await stored("setup_cc4", on: app)?.composite)
            #expect(composite.compositor == .sequence)
            #expect(composite.layout == .count(48))

            // The page now shows Slots. A change back to a grid that also
            // posts a new count reshapes the posted count, not the stored one.
            _ = try await post(
                ["compositor": "tile", "count": "36", "frameRate": "12", "showFailed": "on"],
                to: "/instructor/\(assignment.publicID)/activity/composite", csrf: csrf, cookie: cookie, on: app)
            let regridded = try #require(try await stored("setup_cc4", on: app)?.composite)
            #expect(regridded.layout == .grid(columns: 6, rows: 6))
        }
    }

    @Test func anUnreadableNumberOrABrokenRuleIsRefused() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_cc5", manifest: try compositeManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cc5", title: "Class GPU", isOpen: true, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)
            let path = "/instructor/\(assignment.publicID)/activity/composite"

            #expect(try await post(["cols": "eight"], to: path, csrf: csrf, cookie: cookie, on: app).contains("error="))
            #expect(try await post(["cols": "40"], to: path, csrf: csrf, cookie: cookie, on: app).contains("error="))
            #expect(try await stored("setup_cc5", on: app)?.composite == .starter, "nothing was stored")
        }
    }

    /// Once a student has submitted, the structural inputs render disabled,
    /// and a disabled input is not posted: the endpoint keeps the stored
    /// structure and saves the display settings.
    @Test func afterASubmissionTheStructureIsLockedOnThePage() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_cc6", manifest: try compositeManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cc6", title: "Class GPU", isOpen: true, on: app)
            let student = try await makeTestStudent(on: app, username: "cc6_student")
            try await wrEnrollUser(student, on: app)
            try await wrInsertSubmission(
                id: "sub_cc6", testSetupID: "setup_cc6", userID: try student.requireID(), on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"

            try await app.asyncTest(
                .GET, editPath,
                beforeRequest: { req in req.headers.add(name: .cookie, value: instructorCookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Students have submitted, so these settings are locked."))
                    #expect(html.contains("disabled"))
                })

            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)
            let path = "/instructor/\(assignment.publicID)/activity/composite"
            _ = try await post(["frameRate": "30", "showFailed": "on"], to: path, csrf: csrf, cookie: cookie, on: app)
            let kept = try #require(try await stored("setup_cc6", on: app)?.composite)
            #expect(kept.hasSameStructure(as: .starter))
            #expect(kept.frameRate == 30)

            // A structural field posted anyway is refused by the lock.
            let location = try await post(["cols": "4"], to: path, csrf: csrf, cookie: cookie, on: app)
            #expect(location.contains("error="))
            #expect(try await stored("setup_cc6", on: app)?.composite?.layout == CompositeSpec.starter.layout)
        }
    }
}
