// Tests/APITests/BrightSpace/BrightSpaceSyncSweepGapTests.swift
//
// Paths of the BrightSpace grade-sync sweep that `BrightSpaceGradeSyncTests`
// does not reach: a classlist outage that falls back to the student-number
// lookup, a pending override whose student also has a pending result, the
// chunking of a large `IN` filter, and one tick of the 60-second monitor.
// The DB-backed tests drive the real `BrightSpaceAPIClient` against
// `ScriptedValenceClient`, so no request reaches the network.

import Core
import Fluent
import Foundation
import Logging
import NIOConcurrencyHelpers
import Synchronization
import Testing
import Vapor
import VaporTesting

@testable import APIServer

// MARK: - Log capture

/// Keeps every log message at warning or above, for the classlist fallback.
private final class SweepGapLogCapture: Sendable {
    private let stored = Mutex<[String]>([])

    var logger: Logger {
        Logger(label: "sweep-gap-log-capture.test") { _ in SweepGapLogHandler(sink: self) }
    }

    fileprivate func append(_ message: String) {
        stored.withLock { $0.append(message) }
    }

    func messages(containing fragment: String) -> [String] {
        stored.withLock { messages in messages.filter { $0.contains(fragment) } }
    }
}

private struct SweepGapLogHandler: LogHandler {
    let sink: SweepGapLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .warning

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        sink.append(event.message.description)
    }
}

// MARK: - Fixture

/// A course bound to an org unit, a setup whose suite is worth 10 points, an
/// assignment linked to a LEARN grade item, and one student.
private struct SweepGapFixture {
    let setupID: String
    let userID: UUID

    static let orgUnitID = "ou-gap"
    static let gradeObjectID = "go-gap"

    static func make(on app: Application, studentID: String?) async throws -> SweepGapFixture {
        let course = try await makeTestCourse(on: app, code: "BSGAP")
        course.brightspaceOrgUnitID = orgUnitID
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
        let manifest = #"""
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"t1.sh","points":10}],"timeLimitSeconds":10,"makefile":null}
            """#
        _ = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Gap Lab")
        assignment.brightspaceGradeObjectID = gradeObjectID
        try await assignment.save(on: app.db)

        let user = try await makeTestUser(on: app, username: "gap_\(UUID().uuidString.lowercased().prefix(6))")
        user.studentID = studentID
        try await user.save(on: app.db)
        return SweepGapFixture(setupID: setupID, userID: try user.requireID())
    }

    /// A student submission with one result pending since an hour ago.
    @discardableResult
    func pendingResult(
        on app: Application, earned: Int, kind: String = APISubmission.Kind.student
    )
        async throws -> APIResult
    {
        let submissionID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        _ = try await makeTestSubmission(
            on: app, id: submissionID, setupID: setupID, userID: userID, kind: kind)
        let result = try await makeTestResult(
            on: app, submissionID: submissionID,
            collectionJSON: #"{"earnedPoints":\#(earned),"totalPoints":10}"#)
        result.brightspaceSyncPending = true
        result.brightspacePendingSince = Date().addingTimeInterval(-3600)
        try await result.save(on: app.db)
        return result
    }
}

/// Answers the version discovery with 404 (the fallback versions apply) and
/// hands every other request to `rest`.
private func sweepGapScript(
    _ rest: @escaping @Sendable (HTTPMethod, String) -> ScriptedValenceReply
) -> ScriptedValenceClient.Script {
    { method, url, _ in
        url.contains("/versions/") ? ScriptedValenceReply(.notFound) : rest(method, url)
    }
}

private func sweepGapCalls(_ sent: NIOLockedValueBox<[ScriptedValenceRequest]>) -> [ScriptedValenceRequest] {
    sent.withLockedValue { $0 }.filter { !$0.url.contains("/versions/") }
}

// MARK: - Sweep paths

@Suite(.serialized, .timeLimit(.minutes(3))) struct BrightSpaceSyncSweepGapTests {

    /// A classlist read that fails is not an authoritative "not enrolled":
    /// the sweep logs it and resolves the student through the org-level
    /// student-number lookup, then pushes and caches the resolved id.
    @Test func aClasslistOutageFallsBackToTheStudentNumberLookup() async throws {
        try await withTestApp(prefix: "chickadee-bs-gap") { app in
            let capture = SweepGapLogCapture()
            app.logger = capture.logger
            let fixture = try await SweepGapFixture.make(on: app, studentID: "stu-gap")
            let result = try await fixture.pendingResult(on: app, earned: 7)
            let sent = app.useScriptedValence(
                sweepGapScript { method, url in
                    if url.contains("/classlist/") { return ScriptedValenceReply(.internalServerError) }
                    if url.contains("/users/?orgDefinedId=") {
                        return ScriptedValenceReply(.ok, #"{"Items":[{"UserId":777}],"PagingInfo":null}"#)
                    }
                    if method == .PUT { return ScriptedValenceReply(.ok) }
                    // The grade-object read: 404 means no scaling and no type check.
                    return ScriptedValenceReply(.notFound)
                })
            let client = BrightSpaceAPIClient(config: .scriptedTest)

            let processed = try await sweepBrightSpaceGradeSync(
                on: app.db, debounceSecs: 90, resolveClient: { _ in client },
                logger: app.logger, application: app)

            #expect(processed == 1)
            let calls = sweepGapCalls(sent)
            #expect(calls.contains { $0.url.contains("/users/?orgDefinedId=stu-gap") })
            let puts = calls.filter { $0.method == .PUT }
            #expect(puts.count == 1)
            #expect(puts.first?.url.contains("/grades/\(SweepGapFixture.gradeObjectID)/values/777") == true)
            #expect(!capture.messages(containing: "BrightSpace classlist resolve failed for org unit ou-gap").isEmpty)

            let user = try #require(try await APIUser.find(fixture.userID, on: app.db))
            #expect(user.brightspaceUserID == "777")
            let reloaded = try #require(try await APIResult.find(result.id, on: app.db))
            #expect(reloaded.brightspaceSyncPending == false)
            #expect(reloaded.brightspaceSyncedAt != nil)
            #expect(reloaded.brightspaceSyncError == nil)
        }
    }

    /// An override set while the student had no submissions flags the
    /// override row; a submission before the next sweep flags a result for
    /// the same (student, setup). The sweep pushes once, through the result,
    /// and clears the override row's redundant flag without marking it synced.
    @Test func aPendingOverrideWhoseStudentHasAPendingResultIsPushedOnce() async throws {
        try await withTestApp(prefix: "chickadee-bs-gap") { app in
            let fixture = try await SweepGapFixture.make(on: app, studentID: "stu-both")
            try await applyGradeOverride(
                testSetupID: fixture.setupID, studentUserID: fixture.userID, percent: 50,
                note: nil, grantedByUserID: nil, on: app.db)
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            #expect(override.brightspaceSyncPending == true)
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)
            let result = try await fixture.pendingResult(on: app, earned: 9)

            let classlist =
                #"{"Objects":[{"Identifier":"d2l-both","OrgDefinedId":"stu-both","Username":"x"}],"Next":null}"#
            let sent = app.useScriptedValence(
                sweepGapScript { method, url in
                    if url.contains("/classlist/") { return ScriptedValenceReply(.ok, classlist) }
                    if method == .PUT { return ScriptedValenceReply(.ok) }
                    return ScriptedValenceReply(.notFound)
                })
            let client = BrightSpaceAPIClient(config: .scriptedTest)

            let processed = try await sweepBrightSpaceGradeSync(
                on: app.db, debounceSecs: 90, resolveClient: { _ in client },
                logger: app.logger, application: app)

            #expect(processed == 1, "the result row only; the override row is not a second push")
            let puts = sweepGapCalls(sent).filter { $0.method == .PUT }
            #expect(puts.count == 1)
            #expect(puts.first?.url.contains("/values/d2l-both?") == true)

            let reloadedOverride = try #require(try await APIGradeOverride.find(override.id, on: app.db))
            #expect(reloadedOverride.brightspaceSyncPending == false)
            #expect(reloadedOverride.brightspaceSyncedAt == nil)
            let reloadedResult = try #require(try await APIResult.find(result.id, on: app.db))
            #expect(reloadedResult.brightspaceSyncPending == false)
            #expect(reloadedResult.brightspaceSyncedAt != nil)
        }
    }

    // MARK: Monitor

    /// One tick of the monitor runs the sweep, and the stored sync config's
    /// debounce wins over the app credentials' debounce. The row is a
    /// validation submission, so the tick needs no LEARN client: it clears
    /// the flag.
    @Test func theMonitorTickSweepsWithTheStoredConfigDebounce() async throws {
        try await withTestApp(prefix: "chickadee-bs-gap") { app in
            let monitor = app.brightSpaceGradeSyncMonitor
            #expect(monitor.name == "BrightSpace grade sync")
            #expect(monitor === app.brightSpaceGradeSyncMonitor)

            let fixture = try await SweepGapFixture.make(on: app, studentID: nil)
            let result = try await fixture.pendingResult(
                on: app, earned: 4, kind: APISubmission.Kind.validation)
            // An hour of credentials debounce would hold the row; the stored
            // config's 60 seconds releases it.
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.example", appID: "app", appKey: "key", debounceSecs: 7200)
            app.brightSpaceSyncConfig = BrightSpaceSyncConfig(
                baseURL: "https://learn.example", appID: "app", appKey: "key",
                userID: "u", userKey: "k", debounceSecs: 60)
            defer {
                app.brightSpaceAppCredentials = nil
                app.brightSpaceSyncConfig = nil
            }

            await monitor.sweepOnce(application: app)
            let row = try await APIResult.find(result.id, on: app.db)
            let cleared = row?.brightspaceSyncPending == false

            #expect(cleared, "one tick clears the validation row")
        }
    }
}

// MARK: - IN-filter chunking

@Suite struct BrightSpaceSyncSweepChunkingTests {

    @Test func anEmptyListYieldsNoChunk() {
        let chunks: [[Int]] = chunkedForInFilter([])
        #expect(chunks.isEmpty)
    }

    @Test func aListAtTheLimitIsOneChunk() {
        let items = Array(0..<5000)
        #expect(chunkedForInFilter(items) == [items])
    }

    @Test func aListAboveTheLimitSplitsInOrderWithAShortTail() {
        let items = Array(0..<12_001)
        let chunks = chunkedForInFilter(items)
        #expect(chunks.map(\.count) == [5000, 5000, 2001])
        #expect(chunks.flatMap { $0 } == items)
    }
}
