// Tests/APITests/Groups/HillPerGroupTests.swift
//
// A king-of-the-hill activity run once per lab group (docs/lab-groups.md,
// slice 3b): each lab has its own hill, a challenger plays the champion of
// the group whose session they submitted in, a submission made with no
// session open takes no hill, no lab's champion holds the course's class
// record and a per-group hill seeds none, a student whom staff removed loses the hill and cannot take it, and
// the page shows the champion of the group it shows.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class HillPerGroupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-hill-groups")
    }

    private typealias Fixture = PerGroupActivityFixture

    private let setupID = "hpg_setup"

    /// A per-group hill with ada and ben in Lab 101 and alan in Lab 102.
    private func fixture() async throws -> Fixture {
        try await .make(
            on: app, code: "HPG1", setupID: setupID,
            activity: ClassActivity(kind: .kingOfTheHill, runsPerGroup: true),
            achievements: [ActivityAuthoring.seededChampionRecord],
            students: [("hpg_ada", .a), ("hpg_ben", .a), ("hpg_alan", .b)])
    }

    private func outcome(won: Bool) -> TestOutcome {
        .stub(status: won ? .pass : .fail, metric: 1)
    }

    /// Runs one challenger's job as the claim and result paths do: choose the
    /// opponent, open the row, then land the result.
    @discardableResult
    private func play(_ f: Fixture, userID: UUID, id: String, won: Bool) async throws -> ChosenOpponent {
        let submission = try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
        let chosen = try await chooseOpponent(for: submission, activity: f.activity, on: app.db)
        try await openMatch(
            testSetupID: setupID, submissionID: id, opponent: chosen,
            seed: JobOpponent.matchSeed(submissionID: id, opponentIdentity: chosen.identity), on: app.db)
        try await recordActivityMatch(
            testSetupID: setupID, userID: userID, submissionID: id, outcomes: [outcome(won: won)], on: app.db)
        return chosen
    }

    private func leaderboardRow(_ userID: UUID, in group: UUID) async throws -> APIGroupLeaderboardEntry? {
        try await APIGroupLeaderboardEntry.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$groupID == group)
            .filter(\.$userID == userID)
            .first()
    }

    private func holder(_ group: UUID) async throws -> (any HillHolder)? {
        try await Hill.group(testSetupID: setupID, groupID: group).holder(on: app.db)
    }

    @Test func eachLabHasItsOwnHill() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await f.join(f.ben, to: f.labA, on: app.db)
            try await f.join(f.alan, to: f.labB, on: app.db)

            #expect(try await play(f, userID: f.ada, id: "hpg_a1", won: true).champion == nil)
            #expect(try await holder(f.labA)?.userID == f.ada)

            // Lab 102's hill is empty: alan plays nobody, not ada.
            #expect(try await play(f, userID: f.alan, id: "hpg_l1", won: true).champion == nil)
            #expect(try await holder(f.labB)?.userID == f.alan)
            #expect(try await holder(f.labA)?.userID == f.ada, "Lab 102's result leaves Lab 101's hill")

            // ben plays Lab 101's champion, loses, and ada counts a defence.
            #expect(try await play(f, userID: f.ben, id: "hpg_b1", won: false).champion?.id == "hpg_a1")
            #expect(try await holder(f.labA)?.defences == 1)
            #expect(try await play(f, userID: f.ben, id: "hpg_b2", won: true).champion?.id == "hpg_a1")
            #expect(try await holder(f.labA)?.userID == f.ben)

            #expect(
                try await Hill.course(testSetupID: setupID).holder(on: app.db) == nil, "no course-wide hill")
            let record = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$achievementID == ActivityAuthoring.seededChampionRecordID)
                .first()
            #expect(record == nil, "no lab's champion holds the class record")
        }
    }

    @Test func aSubmissionWithNoSessionTakesNoHill() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await play(f, userID: f.ada, id: "hpg_a2", won: true)

            // ben is a member of Lab 101 and never joined: he plays nobody,
            // and his win moves no hill.
            #expect(try await play(f, userID: f.ben, id: "hpg_b3", won: true).champion == nil)
            #expect(try await holder(f.labA)?.userID == f.ada)
            #expect(try await holder(f.labA)?.defences == 0)
        }
    }

    @Test func aRemovedStudentLosesTheHillAndCannotTakeIt() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await f.join(f.ben, to: f.labA, on: app.db)
            try await play(f, userID: f.ada, id: "hpg_a4", won: true)
            let session = try #require(
                try await ActivitySessionStore.session(assignmentID: f.assignmentID, groupID: f.labA, on: app.db))

            // ben's job is out against ada when staff remove him: his win
            // lands with no session and moves no hill.
            let submission = try await makeTestSubmission(on: app, id: "hpg_b4", setupID: setupID, userID: f.ben)
            let chosen = try await chooseOpponent(for: submission, activity: f.activity, on: app.db)
            #expect(chosen.champion?.id == "hpg_a4")
            try await openMatch(
                testSetupID: setupID, submissionID: "hpg_b4", opponent: chosen,
                seed: JobOpponent.matchSeed(submissionID: "hpg_b4", opponentIdentity: chosen.identity), on: app.db)
            #expect(try await ActivitySessionStore.remove(userID: f.ben, from: session, on: app.db))
            try await recordActivityMatch(
                testSetupID: setupID, userID: f.ben, submissionID: "hpg_b4", outcomes: [outcome(won: true)],
                on: app.db)
            #expect(try await holder(f.labA)?.userID == f.ada)

            // Removing the champion empties the hill and takes their row off
            // the group's leaderboard.
            try await recordLeaderboardEntry(
                testSetupID: setupID, userID: f.ada, submissionID: "hpg_a4", outcomes: [outcome(won: true)],
                on: app.db)
            #expect(try await leaderboardRow(f.ada, in: f.labA) != nil)
            #expect(try await ActivitySessionStore.remove(userID: f.ada, from: session, on: app.db))
            #expect(try await holder(f.labA) == nil)
            #expect(try await leaderboardRow(f.ada, in: f.labA) == nil)
        }
    }

    @Test func aPerGroupHillSeedsNoChampionRecord() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            func hasChampionRecord() async throws -> Bool {
                let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
                return setup.decodedManifest()?.achievements.contains { $0.recordDimension == .champion } == true
            }
            #expect(try await hasChampionRecord(), "the fixture carries the seeded record")
            _ = try await ActivityAuthoring.setActivity(
                setup: f.setup, to: ClassActivity(kind: .kingOfTheHill, runsPerGroup: true), on: app.db)
            #expect(try await !hasChampionRecord())
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            _ = try await ActivityAuthoring.setActivity(
                setup: setup, to: ClassActivity(kind: .kingOfTheHill), on: app.db)
            #expect(try await hasChampionRecord(), "the whole class's hill seeds it again")
        }
    }

    @Test func thePageShowsTheChampionOfTheGroupItShows() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await f.join(f.alan, to: f.labB, on: app.db)
            try await play(f, userID: f.ada, id: "hpg_a3", won: true)
            try await play(f, userID: f.alan, id: "hpg_l3", won: true)

            func championHandle(_ group: UUID?) async throws -> String? {
                try await buildChampionPresentation(
                    setup: f.setup, activity: f.activity, groupID: group, viewerID: f.ada, includeNames: false,
                    on: app.db)?.handle
            }
            let adaHandle = try #require(try await championHandle(f.labA))
            let alanHandle = try #require(try await championHandle(f.labB))
            #expect(adaHandle != alanHandle)
            #expect(try await championHandle(nil) == nil, "a student in no group sees no hill")
            #expect(
                try await buildChampionPresentation(
                    setup: f.setup, activity: f.activity, groupID: f.labA, viewerID: f.ada, includeNames: false,
                    on: app.db)?.isViewer == true)
        }
    }
}

private extension PerGroupActivityFixture {
    var ada: UUID { students[0] }
    var ben: UUID { students[1] }
    var alan: UUID { students[2] }
}
