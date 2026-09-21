// Tests/APITests/ActivityEditPageTests.swift
//
// The instructor edit page's class-activity surface: the "Class activity"
// select (derived from `ActivityKind.allCases`, disabled once a student has
// submitted), the Activity section that renders only when a block is set, and
// the leaderboard-visibility POST that publishes a board without closing or
// re-validating the assignment.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivityEditPageTests {

    private func activityManifest(visible: Bool = false) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(
                kind: .beatTheInstructor, leaderboardVisibility: visible ? .visible : .hidden))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func staff(on app: Application) async throws -> String {
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    @Test func ordinaryAssignmentShowsTheSelectAndNoActivitySection() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae1", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae1", title: "Plain Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("name=\"activityKind\""))
                    for kind in ActivityKind.allCases {
                        #expect(html.contains("value=\"\(kind.rawValue)\""), "\(kind.rawValue)")
                        #expect(html.contains(kind.displayName))
                    }
                    #expect(!html.contains("Save leaderboard setting"))
                    #expect(!html.contains("id=\"activityKindSelect\" disabled"))
                })
        }
    }

    @Test func activityAssignmentShowsTheSectionAndLocksTheSelectAfterASubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae2", manifest: try activityManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae2", title: "Bot Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Save leaderboard setting"))
                    #expect(html.contains("/testsetups/setup_ae2/leaderboard"))
                    #expect(html.contains(ActivityKind.beatTheInstructor.displayName))
                    #expect(!html.contains("id=\"activityKindSelect\" disabled"))
                })

            let student = try await makeTestStudent(on: app, username: "ae2_student")
            try await wrEnrollUser(student, on: app)
            try await wrInsertSubmission(
                id: "sub_ae2", testSetupID: "setup_ae2", userID: try student.requireID(), on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("id=\"activityKindSelect\" disabled"))
                    #expect(html.contains("locked"))
                })
        }
    }

    @Test func visibilityToggleSetsAndClearsWithoutTouchingTheKind() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae3", manifest: try activityManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae3", title: "Toggle Lab", isOpen: false, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "visible": "on"], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            var props = try #require(try await APITestSetup.find("setup_ae3", on: app.db)?.decodedManifest())
            #expect(props.activity == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .visible))

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            props = try #require(try await APITestSetup.find("setup_ae3", on: app.db)?.decodedManifest())
            #expect(props.activity == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .hidden))
        }
    }

    @Test func visibilityToggleBouncesOnAnOrdinaryAssignment() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae4", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae4", title: "Plain Lab", isOpen: false, on: app)
            let (csrf, cookie) = try await csrfFields(
                for: "/instructor/\(assignment.publicID)/edit", cookie: instructorCookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "visible": "on"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })
            let props = try #require(try await APITestSetup.find("setup_ae4", on: app.db)?.decodedManifest())
            #expect(props.activity == nil)
        }
    }

    // MARK: - The opponent picker (docs/class-activities.md, slice 2)

    private func opponentManifest(opponentFile: String? = nil) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .beatTheInstructor, opponentFile: opponentFile))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func writeSupportFiles(_ names: [String], setupID: String, on app: Application) async throws {
        let zipPath = app.testSetupsDirectory + "\(setupID).zip"
        try await pfWriteEmptyZip(at: zipPath)
        try await updateScriptInZip(zipPath: zipPath, filename: "match.sh", content: "#!/bin/sh\nexit 0\n")
        for name in names {
            try await updateScriptInZip(zipPath: zipPath, filename: name, content: "print('rock')\n")
        }
    }

    /// The picker renders for a kind that stages an opponent, listing the
    /// setup's support files (not its graded script) with the stored one
    /// selected; it does not render for a kind with no opponent.
    @Test func opponentPickerListsSupportFilesForABotKindOnly() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae5", manifest: try opponentManifest(opponentFile: "bot.py"), on: app)
            try await writeSupportFiles(["bot.py", "helper.py"], setupID: "setup_ae5", on: app)
            let bot = try await wrInsertAssignment(
                testSetupID: "setup_ae5", title: "Bot Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(bot.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("name=\"opponentFile\""))
                    #expect(html.contains("value=\"bot.py\" selected"))
                    #expect(html.contains("value=\"helper.py\""))
                    #expect(!html.contains("value=\"match.sh\""))
                    #expect(html.contains("Save opponent file"))
                    #expect(html.contains("CHICKADEE_OPPONENT_DIR"))
                })

            try await wrInsertSetup(id: "setup_ae6", manifest: try activityManifest(), on: app)
            let metric = try await wrInsertAssignment(
                testSetupID: "setup_ae6", title: "Metric Lab", isOpen: false, on: app)
            _ = metric
            let props = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")],
                activity: ClassActivity(kind: .bestMetric))
            let setup = try #require(try await APITestSetup.find("setup_ae6", on: app.db))
            setup.manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
            try await setup.save(on: app.db)
            try await app.asyncTest(
                .GET, "/instructor/\(metric.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(!res.body.string.contains("name=\"opponentFile\""))
                })
        }
    }

    /// The POST chooses a support file, keeps the leaderboard visibility, and
    /// clears with an empty value; a file the setup lacks bounces with the
    /// refusal in the banner and leaves the block untouched.
    @Test func opponentPickerSetsAndClearsWithoutTouchingVisibility() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae7", manifest: try activityManifest(visible: true), on: app)
            try await writeSupportFiles(["bot.py"], setupID: "setup_ae7", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae7", title: "Pick Lab", isOpen: false, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)
            let postPath = "/instructor/\(assignment.publicID)/activity/opponent"

            try await app.asyncTest(
                .POST, postPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "opponentFile": "bot.py"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("notice=") == true)
                })
            var props = try #require(try await APITestSetup.find("setup_ae7", on: app.db)?.decodedManifest())
            #expect(
                props.activity
                    == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .visible, opponentFile: "bot.py"))

            try await app.asyncTest(
                .POST, postPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "opponentFile": "ghost.py"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })
            props = try #require(try await APITestSetup.find("setup_ae7", on: app.db)?.decodedManifest())
            #expect(props.activity?.opponentFile == "bot.py")

            try await app.asyncTest(
                .POST, postPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "opponentFile": ""], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            props = try #require(try await APITestSetup.find("setup_ae7", on: app.db)?.decodedManifest())
            #expect(props.activity == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .visible))
        }
    }

    /// The visibility toggle rebuilds from the stored block, so it cannot
    /// drop a chosen opponent file.
    @Test func visibilityToggleKeepsTheOpponentFile() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae8", manifest: try opponentManifest(opponentFile: "bot.py"), on: app)
            try await writeSupportFiles(["bot.py"], setupID: "setup_ae8", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae8", title: "Keep Lab", isOpen: false, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "visible": "on"], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            let props = try #require(try await APITestSetup.find("setup_ae8", on: app.db)?.decodedManifest())
            #expect(
                props.activity
                    == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .visible, opponentFile: "bot.py"))
        }
    }
}
