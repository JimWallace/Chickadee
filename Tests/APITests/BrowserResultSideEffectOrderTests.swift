// Tests/APITests/BrowserResultSideEffectOrderTests.swift
//
// A graded browser result must be STORED before anything optional runs, and
// nothing optional may fail the request.
//
// This is the `grading-probe` intermittent, closed. Three sightings, all the
// same shape: the breadcrumb trail reached `suite_done` — grading finished, one
// test, passed — and then `submit_failed [500]`. The page went on polling
// `GET /api/v1/submissions/:id` and getting 200 for the probe's full 300-second
// budget, which is the tell: the SUBMISSION row existed and the RESULT did not.
// Something between the two threw.
//
// In the probe's configuration exactly one thing sat in that window that could:
// `awardFirstToSubmitRecords`, an unguarded read-then-write. (Its neighbour,
// `flagResultForBrightSpaceSync`, only reads, and returns immediately when no
// BrightSpace credentials are configured — which is the smoke's case.)
//
// WHY IT THREW AT ALL, given SQLite is meant to wait. sqlite-nio installs a
// busy handler that returns 1 forever, so ordinary lock contention never
// surfaces as an error — which is why "add a busy_timeout" is the wrong fix and
// why this took three sightings to place. What a busy handler cannot cover is
// `SQLITE_BUSY_SNAPSHOT`: a WAL read snapshot made stale by another
// connection's commit. SQLite returns that IMMEDIATELY, bypassing the handler,
// because waiting cannot help — only restarting the transaction can, which is
// what `withTransientDatabaseLockRetry` does. Every badge helper is
// read-then-write, the exact shape that hits it, and the page's own result
// polling supplies the concurrent commits.
//
// The fix is two things, and the second is the one that matters: retry the
// side effects, and make them unable to fail the request either way. A class
// badge is worth an ordinary amount. A student's grade is not worth losing for
// one.
//
// This test reads the handler's STRUCTURE, because the failure it guards is an
// ordering property and reproducing a snapshot race on demand would be a test
// that passes for the wrong reason on a quiet machine.
//
// The side effects live in `awardBrowserResultBadges`, extracted so the
// ordering is visible at the call site rather than buried 60 lines into the
// handler. So there are two assertions: the handler saves the result before it
// calls that method, and that method cannot throw.

import Foundation
import Testing

@testable import APIServer

@Suite struct BrowserResultSideEffectOrderTests {

    private static func handlerBody() throws -> String {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // APITests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("Sources/APIServer/Routes/BrowserResultRoutes.swift"),
            encoding: .utf8)
        let start = try #require(
            source.range(of: "func submitBrowserResult(req: Request)"),
            "submitBrowserResult has been renamed — re-point this guard")
        // The handler ends where the next one begins.
        let end = source.range(of: "func submitRunnerSubmission(req: Request)")
        return String(source[start.lowerBound..<(end?.lowerBound ?? source.endIndex)])
    }

    @Test func theResultIsStoredBeforeAnyBadgeIsAwarded() throws {
        let body = try Self.handlerBody()
        let resultSave = try #require(
            body.range(of: "saveWithCollection"), "the result save has moved — re-point this guard")
        for sideEffect in [
            "awardBrowserResultBadges", "awardFirstToSubmitRecords",
            "awardClassBadgesFor100Percent",
        ] {
            guard let call = body.range(of: sideEffect) else { continue }
            #expect(
                resultSave.lowerBound < call.lowerBound,
                """
                \(sideEffect) runs BEFORE the result is stored. If it throws, the submission row \
                exists and the result does not — the browser reports "Failed to submit results" \
                for a submission that graded perfectly, and the page polls a row that will never \
                have a result. That is the grading-probe intermittent; see this file's header.
                """)
        }
    }

    /// The extracted side-effect method, which is where the wrapper lives.
    private static func sideEffectBody() throws -> String {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/APIServer/Routes/BrowserResultRoutes.swift"),
            encoding: .utf8)
        let start = try #require(
            source.range(of: "private func awardBrowserResultBadges("),
            "awardBrowserResultBadges has been renamed — re-point this guard")
        let end = source.range(of: "func submitRunnerSubmission(req: Request)")
        return String(source[start.lowerBound..<(end?.lowerBound ?? source.endIndex)])
    }

    @Test func noSideEffectCanFailTheRequest() throws {
        let body = try Self.sideEffectBody()
        #expect(
            body.contains("func bestEffort("),
            "the best-effort wrapper is gone; a badge failure can 500 a stored grade again")
        for sideEffect in ["awardFirstToSubmitRecords", "awardClassBadgesFor100Percent"] {
            guard let call = body.range(of: sideEffect) else { continue }
            // The wrapper opens within a line or two above the call it guards:
            // `await bestEffort("…") {` then `try await <call>(`. Looking at a
            // bounded window rather than the whole preceding body, so a
            // `bestEffort` used earlier for a different side effect cannot
            // vouch for this one.
            let preceding = body[body.startIndex..<call.lowerBound]
            let window = String(preceding.suffix(160))
            #expect(
                window.contains("bestEffort("),
                """
                \(sideEffect) is not inside `bestEffort`, so it can throw and turn a stored grade \
                into a 500. Wrap it — it retries the transient WAL snapshot race and logs anything \
                that survives.
                """)
        }
    }

    /// The retry is what makes "best effort" actually award the badge most of
    /// the time, rather than quietly dropping it on the first stale snapshot.
    @Test func theBestEffortWrapperRetriesRatherThanOnlySwallowing() throws {
        let body = try Self.sideEffectBody()
        let wrapper = try #require(body.range(of: "func bestEffort("))
        let after = body[wrapper.upperBound...].prefix(400)
        #expect(
            after.contains("withTransientDatabaseLockRetry"),
            "bestEffort swallows without retrying, so a transient race silently loses the badge")
        #expect(
            after.contains("logger.warning"),
            "a swallowed failure must still be visible in the logs")
    }
}
