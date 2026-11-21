// Tests/APITests/Gamification/LiveBoardRefreshTests.swift
//
// The live board's fast path (docs/live-board-cache.md): a refresh answered
// 304 from the fingerprint while nothing changed, a refresh that sees every
// change, a board built from the shared roster snapshot that matches the one
// built from the database, and the pieces each depends on.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct LiveBoardRefreshTests {

    private func manifest(_ activity: ClassActivity) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil, activity: activity)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// The logged-in student and `classmates` more, each ranked.
    @discardableResult
    private func seedBoard(
        on app: Application, setupID: String, classmates: Int = 3,
        activity: ClassActivity = ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible)
    ) async throws -> [APIUser] {
        let setup = try await wrInsertSetup(id: setupID, manifest: try manifest(activity), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: setup.courseID, title: "Race \(setupID)")
        var users = [try await wrStudentUser(on: app)]
        for index in 0..<classmates {
            users.append(try await makeTestUser(on: app, username: "\(setupID)_\(index)", role: "student"))
        }
        for (index, user) in users.enumerated() {
            try await wrEnrollUser(user, on: app)
            try await APILeaderboardEntry(
                testSetupID: setupID, userID: try user.requireID(), submissionID: "\(setupID)_\(index)",
                metric: Double(10 * (index + 1)), reachedAt: Date()
            ).save(on: app.db)
        }
        return users
    }

    /// The web routes app with the live board's clock pinned. The tag and the
    /// roster snapshot both include a 30-second time bucket, so on the wall
    /// clock two refreshes could fall either side of a bucket edge and get
    /// different tags; a pinned clock keeps every refresh of a test in one
    /// bucket.
    private func withBoardApp(_ body: (Application) async throws -> Void) async throws {
        try await withTestApp { app in
            app.liveBoardClock = .fixed(at: Date(timeIntervalSince1970: 1_800_000_000))
            try await body(app)
        }
    }

    private func refresh(
        _ path: String, cookie: String, etag: String? = nil, on app: Application
    ) async throws -> TestResponse {
        try await app.asyncSendRequest(.GET, path) { req in
            req.headers.add(name: .cookie, value: cookie)
            if let etag { req.headers.add(name: .ifNoneMatch, value: etag) }
        }
    }

    // MARK: - The refresh

    @Test func anUnchangedBoardIsAnswered304() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(on: app, setupID: "lbr_304")
            let path = "/testsetups/lbr_304/leaderboard?fragment=body"

            let first = try await refresh(path, cookie: cookie, on: app)
            #expect(first.status == .ok)
            let etag = try #require(first.headers.first(name: .eTag))
            #expect(etag.hasPrefix("W/\"lb-"))

            let second = try await refresh(path, cookie: cookie, etag: etag, on: app)
            #expect(second.status == .notModified)
            #expect(second.body.readableBytes == 0)
            #expect(second.headers.first(name: .eTag) == etag)
        }
    }

    @Test func aNewBestChangesTheTagAndTheRows() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let users = try await seedBoard(on: app, setupID: "lbr_new")
            let path = "/testsetups/lbr_new/leaderboard?fragment=body"
            let etag = try #require(try await refresh(path, cookie: cookie, on: app).headers.first(name: .eTag))

            // The viewer raises their best past everyone.
            let viewerID = try users[0].requireID()
            let entry = try #require(
                try await APILeaderboardEntry.query(on: app.db).filter(\.$userID == viewerID)
                    .filter(\.$testSetupID == "lbr_new").first())
            entry.metric = 999
            try await entry.save(on: app.db)

            let after = try await refresh(path, cookie: cookie, etag: etag, on: app)
            #expect(after.status == .ok)
            #expect(after.headers.first(name: .eTag) != etag)
            #expect(after.body.string.contains(">999<"))
        }
    }

    @Test func aStaffTagChangesWithASubmissionThatSetsNoBest() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            // The board's first row is the student account.
            _ = try await wrLoginAsStudent(on: app)
            let users = try await seedBoard(on: app, setupID: "lbr_staff")
            let path = "/testsetups/lbr_staff/leaderboard?fragment=body"
            let etag = try #require(try await refresh(path, cookie: cookie, on: app).headers.first(name: .eTag))
            #expect(try await refresh(path, cookie: cookie, etag: etag, on: app).status == .notModified)

            // A staff row counts submissions, which a result changes without
            // changing anyone's best.
            _ = try await makeTestSubmission(
                on: app, id: "lbr_staff_extra", setupID: "lbr_staff", userID: try users[1].requireID())
            #expect(try await refresh(path, cookie: cookie, etag: etag, on: app).status == .ok)
        }
    }

    @Test func eachViewerHasTheirOwnTag() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(on: app, setupID: "lbr_own")
            let window = try await refresh(
                "/testsetups/lbr_own/leaderboard?fragment=body", cookie: cookie, on: app)
            let all = try await refresh(
                "/testsetups/lbr_own/leaderboard?fragment=body&all=1", cookie: cookie, on: app)
            #expect(window.headers.first(name: .eTag) != all.headers.first(name: .eTag))
        }
    }

    @Test func aBoardWithAHillIsBuiltEveryTime() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(
                on: app, setupID: "lbr_hill",
                activity: ClassActivity(kind: .kingOfTheHill, leaderboardVisibility: .visible))
            let res = try await refresh("/testsetups/lbr_hill/leaderboard?fragment=body", cookie: cookie, on: app)
            #expect(res.status == .ok)
            #expect(res.headers.first(name: .eTag)?.hasPrefix("W/\"lb-") == false)
        }
    }

    // MARK: - The shared snapshot

    @Test func aBoardFromTheSnapshotMatchesOneFromTheDatabase() async throws {
        try await withBoardApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let users = try await seedBoard(on: app, setupID: "lbr_parity", classmates: 6)
            let setup = try #require(try await APITestSetup.find("lbr_parity", on: app.db))
            let viewer = users[2]
            let entries = try await leaderboardEntries(testSetupID: "lbr_parity", on: app.db)
            let snapshot = try await RosterSnapshot.capture(
                userIDs: entries.map(\.userID), courseID: setup.courseID, on: app.db)

            for isStaff in [false, true] {
                for showAll in [false, true] {
                    let reader = LeaderboardReader.page(user: viewer, isStaff: isStaff)
                    let built = try await buildLeaderboard(
                        setup: setup, reader: reader, showAll: showAll, on: app.db)
                    let shared = try await buildLeaderboard(
                        setup: setup, reader: reader, showAll: showAll, roster: snapshot, on: app.db)
                    let context = "staff \(isStaff), all \(showAll)"
                    #expect(built.rows.map(\.handle) == shared.rows.map(\.handle), "\(context)")
                    #expect(built.rows.map(\.name) == shared.rows.map(\.name), "\(context)")
                    #expect(built.rows.map(\.username) == shared.rows.map(\.username), "\(context)")
                    #expect(built.rows.map(\.rankText) == shared.rows.map(\.rankText), "\(context)")
                    #expect(built.rows.map(\.isViewer) == shared.rows.map(\.isViewer), "\(context)")
                    #expect(built.rows.map(\.avatar) == shared.rows.map(\.avatar), "\(context)")
                    #expect(built.rows.map(\.tieNote) == shared.rows.map(\.tieNote), "\(context)")
                    #expect(built.rows.map(\.bestAtISO) == shared.rows.map(\.bestAtISO), "\(context)")
                    #expect(built.rankedCount == shared.rankedCount)
                    #expect(built.you.map(String.init(describing:)) == shared.you.map(String.init(describing:)))
                }
            }
        }
    }

    @Test func aSnapshotThatMissesARankedStudentIsNotUsed() async throws {
        try await withBoardApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let users = try await seedBoard(on: app, setupID: "lbr_miss")
            let setup = try #require(try await APITestSetup.find("lbr_miss", on: app.db))
            // Captured before the last student ranked.
            let snapshot = try await RosterSnapshot.capture(
                userIDs: try users.dropLast().map { try $0.requireID() }, courseID: setup.courseID, on: app.db)
            #expect(!snapshot.covers(try users.map { try $0.requireID() }))
            let board = try await buildLeaderboard(
                setup: setup, reader: .page(user: users[0], isStaff: true), showAll: true, roster: snapshot,
                on: app.db)
            #expect(board.rankedCount == users.count)
        }
    }

    @Test func theDigestFollowsAHandle() async throws {
        try await withBoardApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let users = try await seedBoard(on: app, setupID: "lbr_digest")
            let setup = try #require(try await APITestSetup.find("lbr_digest", on: app.db))
            let ids = try users.map { try $0.requireID() }
            let before = try await RosterSnapshot.capture(userIDs: ids, courseID: setup.courseID, on: app.db)
            let again = try await RosterSnapshot.capture(userIDs: ids, courseID: setup.courseID, on: app.db)
            #expect(before.digest == again.digest)

            let renamed = try #require(try await APIUser.find(ids[1], on: app.db))
            renamed.avatarHandle = "Quiet Cedar"
            try await renamed.save(on: app.db)
            let after = try await RosterSnapshot.capture(userIDs: ids, courseID: setup.courseID, on: app.db)
            #expect(after.digest != before.digest)
        }
    }

    @Test func refreshesAtOneFingerprintShareOneCapture() async throws {
        let snapshots = LiveBoardSnapshots()
        let captures = CaptureCounter()
        let empty = RosterSnapshot(members: [:], capturedIDs: [], digest: "d")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try await snapshots.snapshot(testSetupID: "s", groupID: nil, fingerprint: "f1") {
                        await captures.increment()
                        try await Task.sleep(for: .milliseconds(20))
                        return empty
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await captures.value == 1)

        _ = try await snapshots.snapshot(testSetupID: "s", groupID: nil, fingerprint: "f2") {
            await captures.increment()
            return empty
        }
        #expect(await captures.value == 2)
        #expect(await snapshots.count == 1)
    }

    @Test func aFailedCaptureIsTriedAgain() async throws {
        let snapshots = LiveBoardSnapshots()
        let empty = RosterSnapshot(members: [:], capturedIDs: [], digest: "d")
        await #expect(throws: CaptureFailure.self) {
            _ = try await snapshots.snapshot(testSetupID: "s", groupID: nil, fingerprint: "f") {
                throw CaptureFailure()
            }
        }
        let snapshot = try await snapshots.snapshot(testSetupID: "s", groupID: nil, fingerprint: "f") { empty }
        #expect(snapshot.digest == "d")
    }

    // MARK: - The pieces

    @Test(arguments: [
        (ActivityKind.bestMetric, true), (.beatTheInstructor, true), (.kingOfTheHill, false),
        (.roundRobin, false), (.elimination, false), (.testsVersusImplementations, false),
        (.classComposite, false), (.bugHunt, false),
    ])
    func onlyAMetricBoardWithoutAHillTakesTheFastPath(kind: ActivityKind, expected: Bool) {
        #expect(WebRoutes.takesLiveBoardFastPath(ClassActivity(kind: kind)) == expected)
    }

    @Test func theTagChangesWithEachPartAndOnlyThen() {
        let reader = LiveBoardETag.Reader(viewerID: UUID(), isStaff: false, query: "fragment=body")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func tag(
            _ fingerprint: String = "1:2:3", digest: String = "r", reader: LiveBoardETag.Reader? = nil,
            window: String = "open", at time: Date? = nil, build: String = ChickadeeVersion.current
        ) -> String {
            LiveBoardETag.tag(
                fingerprint: fingerprint, rosterDigest: digest,
                reader: reader
                    ?? LiveBoardETag.Reader(
                        viewerID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"), isStaff: false,
                        query: "fragment=body"),
                windowState: window, now: time ?? now, build: build)
        }
        let base = tag()
        #expect(base == tag())
        #expect(base == tag(at: now.addingTimeInterval(1)))
        let variants = [
            tag("1:2:4"),
            tag(digest: "s"),
            tag(window: "afterClose"),
            tag(reader: .init(viewerID: reader.viewerID, isStaff: true, query: reader.query)),
            tag(reader: .init(viewerID: reader.viewerID, isStaff: false, query: "fragment=body&all=1")),
            tag(at: now.addingTimeInterval(LiveBoardETag.bucketSeconds)),
            tag(build: "0.0.0"),
        ]
        #expect(Set(variants).count == variants.count)
        #expect(!variants.contains(base))
    }

    @Test func aBoardRefreshIsAHotPath() {
        #expect(HotPathRoute(method: "GET", path: "/testsetups/setup_1/leaderboard") == .leaderboardRefresh)
        #expect(HotPathRoute(method: "GET", path: "/testsetups/setup_1/leaderboard/extra") == nil)
        #expect(HotPathRoute(method: "GET", path: "/testsetups/setup_1/notebook") == nil)
        #expect(HotPathRoute(method: "POST", path: "/testsetups/setup_1/leaderboard") == nil)
        // Only a 304 skips the metrics row: a built board, of any kind, and
        // the page load keep theirs.
        #expect(HotPathRoute.leaderboardRefresh.isRoutineSuccess(statusCode: 304))
        #expect(!HotPathRoute.leaderboardRefresh.isRoutineSuccess(statusCode: 200))
        #expect(!HotPathRoute.leaderboardRefresh.isRoutineSuccess(statusCode: 404))
    }

    @Test func theWallStopsFourHoursOnOrAtALaterClose() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fourHours = iso8601String(now.addingTimeInterval(4 * 60 * 60))
        // A lecture's window closes before the cap: the cap wins, so a
        // window extended during the lecture cannot freeze the wall.
        let soon = ClassActivity(
            kind: .bestMetric, window: LiveSessionWindow(opensAt: nil, closesAt: now.addingTimeInterval(50 * 60)))
        #expect(PresentModePresentation.pollUntil(soon, now: now) == fourHours)
        let late = now.addingTimeInterval(6 * 60 * 60)
        let long = ClassActivity(kind: .bestMetric, window: LiveSessionWindow(opensAt: nil, closesAt: late))
        #expect(PresentModePresentation.pollUntil(long, now: now) == iso8601String(late))
        #expect(PresentModePresentation.pollUntil(ClassActivity(kind: .bestMetric), now: now) == fourHours)
    }

    /// The refresh reads the app's clock, not the wall clock: the next bucket
    /// on that clock changes the tag, so the old one is no longer a 304.
    @Test func theTagFollowsTheAppsClock() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(on: app, setupID: "lbr_clock")
            let path = "/testsetups/lbr_clock/leaderboard?fragment=body"

            let first = try await refresh(path, cookie: cookie, on: app)
            let etag = try #require(first.headers.first(name: .eTag))
            #expect(try await refresh(path, cookie: cookie, etag: etag, on: app).status == .notModified)

            app.liveBoardClock = .fixed(
                at: Date(timeIntervalSince1970: 1_800_000_000 + LiveBoardETag.bucketSeconds))
            let later = try await refresh(path, cookie: cookie, etag: etag, on: app)
            #expect(later.status == .ok)
            #expect(later.headers.first(name: .eTag) != etag)
        }
    }

    @Test func theWallsRefreshIsAnswered304Too() async throws {
        try await withBoardApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            _ = try await wrLoginAsStudent(on: app)
            try await seedBoard(on: app, setupID: "lbr_wall")
            let path = "/testsetups/lbr_wall/leaderboard?present=1&fragment=present"

            let first = try await refresh(path, cookie: cookie, on: app)
            #expect(first.status == .ok)
            let etag = try #require(first.headers.first(name: .eTag))
            #expect(etag.hasPrefix("W/\"lb-"))
            #expect(try await refresh(path, cookie: cookie, etag: etag, on: app).status == .notModified)

            // The page itself carries the stop time.
            let page = try await refresh("/testsetups/lbr_wall/leaderboard?present=1", cookie: cookie, on: app)
            #expect(page.body.string.contains("data-poll-until="))
        }
    }
}

private actor CaptureCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct CaptureFailure: Error {}
