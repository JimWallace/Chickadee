// Tests/APITests/ActivitySessionWindowTests.swift
//
// The live-session window (docs/class-activities.md, slice 8): the clock a
// class activity runs to, separate from the assignment's due date.
//
// The rules pinned here are the ones `LiveSessionWindow` and the submission
// gate document — half-open bounds so the countdown and the server agree, a
// refusal that says which side of the window a student is on, staff never
// gated because they run the session, the page counting down and refreshing
// only while a session is open, and a window that cannot be saved backwards.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivitySessionWindowTests {

    // MARK: - The window itself (no DB)

    private func window(_ opens: Date?, _ closes: Date?) -> LiveSessionWindow {
        LiveSessionWindow(opensAt: opens, closesAt: closes)
    }

    /// Half-open on purpose: a countdown that reaches zero has to mean the
    /// same thing to the student watching it and to the server reading the
    /// clock, so the opening instant is in and the closing instant is out.
    @Test func theBoundsAreHalfOpen() {
        let opens = Date(timeIntervalSince1970: 1_000)
        let closes = Date(timeIntervalSince1970: 2_000)
        let session = window(opens, closes)
        #expect(session.state(at: opens.addingTimeInterval(-1)) == .beforeOpen)
        #expect(session.state(at: opens) == .open, "the opening instant is inside")
        #expect(session.state(at: closes.addingTimeInterval(-1)) == .open)
        #expect(session.state(at: closes) == .afterClose, "the closing instant is outside")
    }

    /// Each bound stands alone: an open end runs until the assignment closes,
    /// an open start until a fixed moment.
    @Test func eitherBoundMayStandAlone() {
        let now = Date(timeIntervalSince1970: 1_500)
        let opensOnly = window(Date(timeIntervalSince1970: 1_000), nil)
        #expect(opensOnly.accepts(at: now))
        #expect(opensOnly.nextBoundary(at: now) == nil, "nothing left to count down to")

        let closesOnly = window(nil, Date(timeIntervalSince1970: 2_000))
        #expect(closesOnly.accepts(at: now))
        #expect(closesOnly.nextBoundary(at: now) == Date(timeIntervalSince1970: 2_000))
    }

    /// The countdown's target follows the state, so one attribute serves both
    /// halves of a session.
    @Test func theNextBoundaryIsWhicheverComesNext() {
        let opens = Date(timeIntervalSince1970: 1_000)
        let closes = Date(timeIntervalSince1970: 2_000)
        let session = window(opens, closes)
        #expect(session.nextBoundary(at: Date(timeIntervalSince1970: 0)) == opens)
        #expect(session.nextBoundary(at: Date(timeIntervalSince1970: 1_500)) == closes)
        #expect(session.nextBoundary(at: Date(timeIntervalSince1970: 3_000)) == nil)
    }

    /// An unbounded window is no window: it is never stored as an empty block,
    /// so "has a window" is one question rather than two.
    @Test func anUnboundedWindowIsNotStored() {
        let activity = ClassActivity(kind: .bestMetric, window: LiveSessionWindow())
        #expect(activity.window == nil)
        #expect(activity.acceptsSubmissions(at: Date()), "no window accepts whenever the assignment does")
    }

    /// A bound that does not parse reads as no bound — the window fails OPEN,
    /// because a typo an instructor cannot see must not lock a class out of
    /// their own session. The save-time refusal is what keeps it rare.
    @Test func anUnreadableBoundFailsOpen() {
        let session = LiveSessionWindow(opensAtISO: "next Tuesday", closesAtISO: nil)
        #expect(session.isBounded, "the authored bound is still there")
        #expect(!session.boundsAreReadable)
        #expect(session.accepts(at: Date()))
    }

    /// The bounds survive a manifest round trip as ISO-8601 strings, which is
    /// what keeps `ManifestCodec`'s "no Date fields" property true.
    @Test func theWindowRoundTripsThroughTheManifest() throws {
        let opens = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = ClassActivity(
            kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil,
            window: window(opens, opens.addingTimeInterval(3_000)))
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], activity: activity)
        let encoded = try JSONEncoder().encode(props)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("2023-11-14T"), "stored as ISO-8601, not as a number")
        let decoded = try JSONDecoder().decode(TestProperties.self, from: encoded)
        #expect(decoded.activity?.window?.opensAt == opens)
        #expect(decoded.activity?.window?.closesAt == opens.addingTimeInterval(3_000))
    }

    /// The three `with…` rebuilds each keep the other two fields, so saving
    /// one of the Activity section's forms cannot drop a neighbour's setting.
    @Test func eachRebuildKeepsTheOtherSettings() {
        let session = window(Date(timeIntervalSince1970: 1_000), nil)
        let activity = ClassActivity(
            kind: .beatTheInstructor, leaderboardVisibility: .visible, opponentFile: "bot.py",
            window: session)
        #expect(activity.withLeaderboardVisibility(.hidden).window == session)
        #expect(activity.withOpponentFile("other.py").window == session)
        #expect(activity.withWindow(nil).opponentFile == "bot.py")
        #expect(activity.withWindow(nil).leaderboardVisibility == .visible)
    }

    // MARK: - Saving one (DB-backed)

    private func manifest(window: LiveSessionWindow?) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(
                kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil,
                window: window))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A window that closes before it opens accepts nothing ever, which no
    /// author means, so it is refused rather than stored.
    @Test func aBackwardsWindowIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "win_back", manifest: try manifest(window: nil),
                zipPath: app.testSetupsDirectory + "win_back.zip", courseID: courseID)
            try await setup.save(on: app.db)
            let current = try #require(setup.decodedManifest()?.activity)
            let backwards = LiveSessionWindow(
                opensAt: Date(timeIntervalSince1970: 2_000),
                closesAt: Date(timeIntervalSince1970: 1_000))

            await #expect(throws: AppError.self) {
                try await ActivityAuthoring.setActivity(
                    setup: setup, to: current.withWindow(backwards), on: app.db)
            }
            #expect(setup.decodedManifest()?.activity?.window == nil, "nothing was stored")
        }
    }

    /// A bound the parser cannot read is refused at save, which is what makes
    /// the fail-open reading above a backstop rather than a behaviour.
    @Test func anUnreadableBoundIsRefusedAtSave() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "win_bad", manifest: try manifest(window: nil),
                zipPath: app.testSetupsDirectory + "win_bad.zip", courseID: courseID)
            try await setup.save(on: app.db)
            let current = try #require(setup.decodedManifest()?.activity)

            await #expect(throws: AppError.self) {
                try await ActivityAuthoring.setActivity(
                    setup: setup,
                    to: current.withWindow(LiveSessionWindow(opensAtISO: "2pm", closesAtISO: nil)),
                    on: app.db)
            }
        }
    }

    // MARK: - The submission gate

    /// One fixture: an open assignment whose activity runs to `window`, plus
    /// an enrolled student and a request to gate.
    private struct Gated {
        let setupID: String
        let student: APIUser
        let staff: APIUser
    }

    private func gatedFixture(
        _ app: Application, prefix: String, window: LiveSessionWindow
    ) async throws -> Gated {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: try manifest(window: window),
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(
            testSetupID: setupID, title: "Contest \(prefix)", isOpen: true, on: app)
        let student = try await arInsertStudent(username: "\(prefix)_student", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        let staff = try await arInsertStudent(username: "\(prefix)_staff", on: app)
        try await APICourseEnrollment(
            userID: try staff.requireID(), courseID: courseID, role: .instructor
        ).save(on: app.db)
        return Gated(setupID: setupID, student: student, staff: staff)
    }

    private func request(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.any())
    }

    /// Before the window opens and after it closes a submission is refused,
    /// and the two refusals say different things — "closed" alone would send a
    /// student looking for an extension that is not what is in their way.
    @Test func submissionsOutsideTheWindowAreRefusedWithTheReasonWhy() async throws {
        try await withAssignmentRoutesApp { app in
            let soon = Date().addingTimeInterval(3_600)
            let fx = try await gatedFixture(
                app, prefix: "early", window: LiveSessionWindow(opensAt: soon, closesAt: nil))
            await #expect(throws: AssignmentSubmissionGateError.self) {
                _ = try await requireOpenStudentAssignment(
                    for: fx.setupID, user: fx.student, gate: .submission, on: request(app))
            }
            #expect(
                AssignmentSubmissionGateError.activityNotYetOpen(opensAtText: "2 p.m.").reason
                    .contains("opens at"))
            #expect(
                AssignmentSubmissionGateError.activityClosed(closedAtText: "3 p.m.").reason
                    .contains("closed at"))
        }
    }

    @Test func aSubmissionInsideTheWindowIsLetThrough() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await gatedFixture(
                app, prefix: "during",
                window: LiveSessionWindow(
                    opensAt: Date().addingTimeInterval(-60),
                    closesAt: Date().addingTimeInterval(3_600)))
            let gated = try await requireOpenStudentAssignment(
                for: fx.setupID, user: fx.student, gate: .submission, on: request(app))
            #expect(gated != nil)
        }
    }

    /// Reading is not handing in: the notebook page, the setup download and
    /// the seed stay available outside the window, so a student can read the
    /// prompt before the session and their work after it.
    @Test func accessIsNotGatedByTheWindow() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await gatedFixture(
                app, prefix: "access",
                window: LiveSessionWindow(opensAt: Date().addingTimeInterval(3_600), closesAt: nil))
            let gated = try await requireOpenStudentAssignment(
                for: fx.setupID, user: fx.student, gate: .access, on: request(app))
            #expect(gated != nil)
        }
    }

    /// Staff run the session, so the window never locks them out of their own
    /// contest — starting it, testing the bot, submitting a demonstration.
    @Test func courseStaffAreNotGated() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await gatedFixture(
                app, prefix: "staff",
                window: LiveSessionWindow(opensAt: nil, closesAt: Date().addingTimeInterval(-60)))
            await #expect(throws: AssignmentSubmissionGateError.self) {
                _ = try await requireOpenStudentAssignment(
                    for: fx.setupID, user: fx.student, gate: .submission, on: request(app))
            }
            let gated = try await requireOpenStudentAssignment(
                for: fx.setupID, user: fx.staff, gate: .submission, on: request(app))
            #expect(gated != nil, "an instructor is never locked out of their own session")
        }
    }

    /// An activity with no window accepts whenever the assignment does, which
    /// is what keeps every activity before this slice on its own path.
    @Test func anActivityWithNoWindowIsUnaffected() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "nowin_setup", manifest: try manifest(window: nil),
                zipPath: app.testSetupsDirectory + "nowin_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "nowin_setup", title: "No window", isOpen: true, on: app)
            let student = try await arInsertStudent(username: "nowin_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)

            let gated = try await requireOpenStudentAssignment(
                for: "nowin_setup", user: student, gate: .submission, on: request(app))
            #expect(gated != nil)
        }
    }

    // MARK: - What the page shows

    /// Open: a "Closes" countdown, and the page refreshes itself.
    @Test func anOpenSessionCountsDownAndPolls() throws {
        let closes = Date().addingTimeInterval(1_800)
        let activity = ClassActivity(
            kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil,
            window: LiveSessionWindow(opensAt: Date().addingTimeInterval(-60), closesAt: closes))
        let shown = try #require(LiveSessionPresentation.make(activity))
        #expect(shown.label == "Closes")
        #expect(shown.isOpen)
        #expect(!shown.isClosed)
        #expect(!shown.boundaryISO.isEmpty, "the countdown reads this attribute")
    }

    /// Before it opens: an "Opens" countdown.
    @Test func aPendingSessionCountsDownToItsStart() throws {
        let activity = ClassActivity(
            kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil,
            window: LiveSessionWindow(opensAt: Date().addingTimeInterval(600), closesAt: nil))
        let shown = try #require(LiveSessionPresentation.make(activity))
        #expect(shown.label == "Opens")
        #expect(!shown.isOpen)
    }

    /// Closed: a statement rather than a countdown, and the refresh stops.
    @Test func aClosedSessionStatesWhenItEnded() throws {
        let activity = ClassActivity(
            kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil,
            window: LiveSessionWindow(opensAt: nil, closesAt: Date().addingTimeInterval(-600)))
        let shown = try #require(LiveSessionPresentation.make(activity))
        #expect(shown.label == "Closed")
        #expect(shown.isClosed)
        #expect(!shown.isOpen)
    }

    /// An open-ended session has nothing to count down to and is not closed,
    /// so it gets no line at all: it is just an open assignment.
    @Test func anOpenEndedSessionShowsNoLine() {
        let activity = ClassActivity(
            kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil,
            window: LiveSessionWindow(opensAt: Date().addingTimeInterval(-60), closesAt: nil))
        #expect(LiveSessionPresentation.make(activity) == nil)
    }

    @Test func anActivityWithNoWindowShowsNoLine() {
        #expect(LiveSessionPresentation.make(ClassActivity(kind: .bestMetric)) == nil)
    }

    // MARK: - When the page keeps itself current

    /// Whether the page REFRESHES is a different question from whether it
    /// shows a line, and conflating them costs both ways: a page opened
    /// before the session would never re-render its server-side "Opens"
    /// label while the countdown ticked past it, and an open-ended session —
    /// the one that runs until the instructor stops it — would be the single
    /// shape that never updated.
    @Test func theRefreshFollowsTheSessionRatherThanTheLine() {
        let future = Date().addingTimeInterval(600)
        let past = Date().addingTimeInterval(-600)
        func polls(_ window: LiveSessionWindow?) -> Bool {
            window.map { $0.state(at: Date()) != .afterClose } ?? false
        }
        #expect(polls(LiveSessionWindow(opensAt: future, closesAt: nil)), "before it opens")
        #expect(polls(LiveSessionWindow(opensAt: past, closesAt: future)), "while it runs")
        #expect(
            polls(LiveSessionWindow(opensAt: past, closesAt: nil)),
            "open-ended: no line to show, and everything still to watch")
        #expect(!polls(LiveSessionWindow(opensAt: nil, closesAt: past)), "once it has ended")
        #expect(!polls(nil), "an assignment with no window costs nothing")
    }
}
