// Tests/APITests/Grading/WorkerLongPollTests.swift
//
// The held runner poll (`WorkerLongPoll`, `PendingWorkSignal`): a runner slot
// with no job asks the server to hold its poll, and the server answers as soon
// as a submission is pending instead of leaving it for the runner's next poll.

import ChickadeeTestSupport
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct WorkerLongPollTermsTests {

    @Test(arguments: [nil, 0, -5])
    func noRequestedHoldGrantsNone(requested: Int?) {
        #expect(WorkerLongPoll.grantedHoldSeconds(requested: requested) == nil)
    }

    @Test func aRequestedHoldIsCappedAtTheServerMaximum() {
        #expect(WorkerLongPoll.grantedHoldSeconds(requested: 3) == 3)
        #expect(WorkerLongPoll.grantedHoldSeconds(requested: 3600) == WorkerLongPoll.maxHoldSeconds)
    }

    /// The runner's own request timeout is 30 s, so a hold that long would
    /// time the poll out on the runner's side.
    @Test func theHoldEndsBeforeTheRunnersRequestTimeout() {
        #expect(WorkerLongPoll.requestedHoldSeconds < 30)
        #expect(WorkerLongPoll.maxHoldSeconds < 30)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PendingWorkSignalTests {

    /// A pending count that a test sets.
    private actor CountSource {
        var count = 0
        func set(_ value: Int) { count = value }
    }

    private func waitUntilHeld(_ signal: PendingWorkSignal, count: Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while await signal.heldCount < count {
            guard ContinuousClock.now < deadline else {
                throw IssueRecorded("the wait never registered")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aWaitEndsAtItsDeadline() async {
        let signal = PendingWorkSignal { 0 }
        let started = ContinuousClock.now
        await signal.wait(after: await signal.currentGeneration, until: started + .milliseconds(200))
        #expect(ContinuousClock.now - started >= .milliseconds(200))
        #expect(await signal.heldCount == 0)
    }

    @Test func notifyEndsAWaitEarly() async throws {
        let signal = PendingWorkSignal { 0 }
        let generation = await signal.currentGeneration
        let started = ContinuousClock.now
        let waiter = Task { await signal.wait(after: generation, until: started + .seconds(30)) }
        try await waitUntilHeld(signal)
        await signal.notify()
        await waiter.value
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await signal.currentGeneration != generation)
    }

    /// Work that arrives between the generation read and the wait is not
    /// missed: the wait returns at once.
    @Test func aWaitOnAStaleGenerationReturnsAtOnce() async {
        let signal = PendingWorkSignal { 0 }
        let generation = await signal.currentGeneration
        await signal.notify()
        let started = ContinuousClock.now
        await signal.wait(after: generation, until: started + .seconds(30))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func closeReleasesEveryWaitAndHoldsNoNewOne() async throws {
        let signal = PendingWorkSignal { 0 }
        let generation = await signal.currentGeneration
        let started = ContinuousClock.now
        let first = Task { await signal.wait(after: generation, until: started + .seconds(30)) }
        let second = Task { await signal.wait(after: generation, until: started + .seconds(30)) }
        try await waitUntilHeld(signal, count: 2)
        await signal.close()
        await first.value
        await second.value
        await signal.wait(after: await signal.currentGeneration, until: ContinuousClock.now + .seconds(30))
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await signal.isClosed)
    }

    /// A row made pending by a path that does not call `notify()` still ends
    /// the wait: the watcher sees the pending count rise.
    @Test func theWatcherWakesAWaitWhenThePendingCountRises() async throws {
        let source = CountSource()
        await source.set(2)
        let signal = PendingWorkSignal(watchInterval: .milliseconds(20)) { await source.count }
        let generation = await signal.currentGeneration
        let started = ContinuousClock.now
        let waiter = Task { await signal.wait(after: generation, until: started + .seconds(30)) }
        try await waitUntilHeld(signal)
        // Let the watcher take its first count before the rise.
        try await Task.sleep(for: .milliseconds(100))
        await source.set(3)
        await waiter.value
        #expect(ContinuousClock.now - started < .seconds(10))
        await signal.close()
    }

    /// A pending row that was already there when the poll began to wait did
    /// not satisfy that poll's claim, so it does not wake the poll again.
    @Test func theWatcherDoesNotWakeAWaitForAnUnchangedCount() async throws {
        let signal = PendingWorkSignal(watchInterval: .milliseconds(20)) { 2 }
        let generation = await signal.currentGeneration
        let started = ContinuousClock.now
        await signal.wait(after: generation, until: started + .milliseconds(400))
        #expect(ContinuousClock.now - started >= .milliseconds(400))
        #expect(await signal.currentGeneration == generation)
        await signal.close()
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) final class WorkerLongPollRouteTests {
    private let workerSecret = "long-poll-secret"

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-longpoll")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    @Test func aPollWithNoHoldAnswersAtOnceWithoutTheHeader() async throws {
        try await withApp(app) { _ in
            let response = try await poll(workerID: "lp-plain", longPollSeconds: nil)
            #expect(response.status == .noContent)
            #expect(response.headers.first(name: WorkerLongPoll.heldHeader) == nil)
        }
    }

    @Test func aHeldPollWithNoWorkAnswersWhenTheHoldEnds() async throws {
        try await withApp(app) { _ in
            let started = ContinuousClock.now
            let response = try await poll(workerID: "lp-idle", longPollSeconds: 1)
            #expect(response.status == .noContent)
            #expect(response.headers.first(name: WorkerLongPoll.heldHeader) == "1")
            #expect(ContinuousClock.now - started >= .seconds(1))
        }
    }

    @Test func aHeldPollClaimsWorkThatIsAlreadyPending() async throws {
        try await withApp(app) { _ in
            let submission = try await makePendingSubmission(id: "lp_sub_ready")
            let started = ContinuousClock.now
            let response = try await poll(workerID: "lp-ready", longPollSeconds: WorkerLongPoll.maxHoldSeconds)
            #expect(response.status == .ok)
            #expect(try response.content.decode(Job.self).submissionID == submission.id)
            #expect(ContinuousClock.now - started < .seconds(10))
        }
    }

    /// The student's path: the poll is held when the submission arrives, and
    /// `SubmissionIntake`'s notify hands it to the runner at once.
    @Test func aHeldPollIsAnsweredWithASubmissionThatArrivesDuringTheHold() async throws {
        try await withApp(app) { app in
            let signal = app.pendingWorkSignal
            let started = ContinuousClock.now
            let held = Task { [workerSecret] in
                try await Self.poll(
                    app: app, workerSecret: workerSecret, workerID: "lp-wake",
                    longPollSeconds: WorkerLongPoll.maxHoldSeconds)
            }
            try await waitUntilHeld(signal)

            let submission = try await makePendingSubmission(id: "lp_sub_wake")
            await signal.notify()

            let response = try await held.value
            #expect(response.status == .ok)
            #expect(try response.content.decode(Job.self).submissionID == submission.id)
            #expect(ContinuousClock.now - started < .seconds(WorkerLongPoll.maxHoldSeconds))
            #expect(try await APISubmission.find(submission.requireID(), on: app.db)?.status == "assigned")
        }
    }

    /// A row made pending without a notify (a retest, the reaper, a second
    /// server process) still reaches the held poll, through the watcher.
    @Test func aHeldPollSeesWorkThatArrivesWithoutANotify() async throws {
        try await withApp(app) { app in
            let started = ContinuousClock.now
            let held = Task { [workerSecret] in
                try await Self.poll(
                    app: app, workerSecret: workerSecret, workerID: "lp-watch",
                    longPollSeconds: WorkerLongPoll.maxHoldSeconds)
            }
            try await waitUntilHeld(app.pendingWorkSignal)
            // Let the watcher take its first count before the row arrives.
            try await Task.sleep(for: .milliseconds(1500))

            let submission = try await makePendingSubmission(id: "lp_sub_watch")

            let response = try await held.value
            #expect(response.status == .ok)
            #expect(try response.content.decode(Job.self).submissionID == submission.id)
            #expect(ContinuousClock.now - started < .seconds(WorkerLongPoll.maxHoldSeconds))
        }
    }

    /// Shutdown releases a held poll at once, so a deploy's drain does not
    /// wait for it.
    @Test func closingTheSignalReleasesAHeldPoll() async throws {
        try await withApp(app) { app in
            let started = ContinuousClock.now
            let held = Task { [workerSecret] in
                try await Self.poll(
                    app: app, workerSecret: workerSecret, workerID: "lp-close",
                    longPollSeconds: WorkerLongPoll.maxHoldSeconds)
            }
            try await waitUntilHeld(app.pendingWorkSignal)
            await app.pendingWorkSignal.close()

            let response = try await held.value
            #expect(response.status == .noContent)
            #expect(ContinuousClock.now - started < .seconds(WorkerLongPoll.maxHoldSeconds))
        }
    }

    // MARK: - Helpers

    private func waitUntilHeld(_ signal: PendingWorkSignal) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while await signal.heldCount < 1 {
            guard ContinuousClock.now < deadline else {
                throw IssueRecorded("the poll was never held")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makePendingSubmission(id: String) async throws -> APISubmission {
        let course = APICourse(code: "LP_\(id)", name: "Long poll", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "\(id)_setup"
        let manifest =
            #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#
        try await APITestSetup(id: setupID, manifest: manifest, zipPath: "/tmp/\(setupID).zip", courseID: courseID)
            .save(on: app.db)
        try await APIAssignment(testSetupID: setupID, title: "Long poll \(id)", isOpen: true, courseID: courseID)
            .save(on: app.db)
        let submission = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: "/tmp/\(id).zip",
            attemptNumber: 1,
            status: "pending",
            filename: "submission.zip",
            userID: nil,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        return submission
    }

    private func poll(workerID: String, longPollSeconds: Int?) async throws -> TestResponse {
        try await Self.poll(
            app: app, workerSecret: workerSecret, workerID: workerID, longPollSeconds: longPollSeconds)
    }

    /// Static so a test can send a poll from its own task without the
    /// (non-Sendable) suite instance.
    private static func poll(
        app: Application, workerSecret: String, workerID: String, longPollSeconds: Int?
    ) async throws -> TestResponse {
        let path = "/api/v1/worker/request"
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: "\(workerID).local",
            runnerVersion: ChickadeeVersion.current,
            maxConcurrentJobs: 1,
            activeJobs: 0,
            longPollSeconds: longPollSeconds
        )
        let body = ByteBuffer(data: try JSONEncoder().encode(payload))
        let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: workerSecret)
        return try await app.asyncSendRequest(.POST, path) { req in
            req.headers = headers
            req.body = body
        }
    }
}
