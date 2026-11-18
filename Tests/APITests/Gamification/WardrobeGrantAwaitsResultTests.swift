// Tests/APITests/Gamification/WardrobeGrantAwaitsResultTests.swift
//
// The result page grants a wardrobe item only when it can show the Earned
// toast (#3018 review). The page treats every `SubmissionStatus.awaitsResult`
// state as "waiting" and shows no toast, so the grant must wait for the same
// states. A `.running` retest of a graded submission keeps its old result,
// and before this fix it granted the item with no toast.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct WardrobeGrantAwaitsResultTests {

    private static let achievementName = "Painted a tile"

    /// One curated achievement that grants the cross-fade ring for any
    /// graded submission.
    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],\
        "timeLimitSeconds":10,"builtInAchievementsSeeded":true,"achievements":[{"id":"painted_tile",\
        "name":"\(achievementName)","scope":"individual","conditions":[],"match":"all",\
        "reward":{"type":"wardrobe","label":"\(achievementName)","item":"border.crossfade"}}]}
        """

    /// A submission with a stored result, in the given lifecycle state. A
    /// waiting state with a result is a retest: the old result stays.
    private func gradedSubmission(id: String, setupID: String, status: String, on app: Application) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        try await wrInsertSetup(id: setupID, manifest: Self.manifest, on: app)
        try await wrInsertAssignment(testSetupID: setupID, title: "Paint", isOpen: true, on: app)
        try await wrInsertSubmission(
            id: id, testSetupID: setupID, userID: student.requireID(), status: status, on: app)
        try await wrInsertResult(
            submissionID: id, outcomes: [wrMakeOutcome(name: "test.sh", tier: .pub, status: .pass)], on: app)
    }

    private func crossFadeUnlocks(on app: Application) async throws -> Int {
        let student = try await wrStudentUser(on: app)
        return try await APIWardrobeUnlock.query(on: app.db)
            .filter(\.$userID == student.requireID())
            .filter(\.$item == WardrobeItem.crossFadeRing.rawValue)
            .count()
    }

    @Test func aRunningRetestGrantsNothing() async throws {
        #expect(SubmissionStatus.running.awaitsResult)
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradedSubmission(id: "wgar_s1", setupID: "wgar_a", status: "running", on: app)

            let html = try await getHTML("/submissions/wgar_s1", cookie: cookie, on: app)
            #expect(!html.contains("earned-toast"))
            #expect(try await crossFadeUnlocks(on: app) == 0)
        }
    }

    @Test func aCompleteResultStillGrantsTheItem() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradedSubmission(id: "wgar_s2", setupID: "wgar_b", status: "complete", on: app)

            let html = try await getHTML("/submissions/wgar_s2", cookie: cookie, on: app)
            #expect(html.contains(#"id="earned-toast""#))
            #expect(html.contains("Earned for “\(Self.achievementName)”."))
            #expect(try await crossFadeUnlocks(on: app) == 1)
        }
    }
}
