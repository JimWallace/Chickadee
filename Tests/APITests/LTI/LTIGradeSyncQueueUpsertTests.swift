// Tests/APITests/LTI/LTIGradeSyncQueueUpsertTests.swift
//
// The AGS push queue writes each student's row in one upsert per chunk. A
// row that is already waiting keeps its start time, so a stream of
// submissions cannot hold the push back forever; a row that finished, or
// failed, waits again from now with its error cleared.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct LTIGradeSyncQueueUpsertTests {

    private func rows(_ setupID: String, on app: Application) async throws -> [UUID: APILTIGradeSync] {
        let all = try await APILTIGradeSync.query(on: app.db).filter(\.$testSetupID == setupID).all()
        return Dictionary(all.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func aWaitingRowKeepsItsStartAndADoneRowStartsAgain() async throws {
        try await withTestApp(prefix: "chickadee-lti-upsert") { app in
            let course = try await makeTestCourse(on: app, code: "AGS101")
            course.ltiGradesEnabled = true
            course.ltiPlatformID = UUID()
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let setupID = "setup_lti_upsert"
            try await makeTestSetup(on: app, id: setupID, courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
            let first = try await makeTestStudent(on: app, username: "lti_upsert_a").requireID()
            let second = try await makeTestStudent(on: app, username: "lti_upsert_b").requireID()

            let start = Date(timeIntervalSince1970: 1_000_000)
            // A repeated user in one call is one row.
            try await LTIGradeSyncQueue.queue(
                userIDs: [first, second, first], testSetupID: setupID, on: app.db, now: start)
            var queued = try await rows(setupID, on: app)
            #expect(queued.count == 2)
            #expect(queued[first]?.pending == true)
            #expect(queued[first]?.pendingSince == start)

            // The first student's push finishes, with an error to clear.
            let done = try #require(queued[first])
            done.pending = false
            done.error = "LMS refused"
            done.failure = .notLaunched
            try await done.save(on: app.db)

            let later = start.addingTimeInterval(600)
            try await LTIGradeSyncQueue.queue(userIDs: [first, second], testSetupID: setupID, on: app.db, now: later)
            queued = try await rows(setupID, on: app)
            #expect(queued.count == 2)
            // Done, so it waits again from now, with no error.
            #expect(queued[first]?.pending == true)
            #expect(queued[first]?.pendingSince == later)
            #expect(queued[first]?.error == nil)
            #expect(queued[first]?.failureReason == nil)
            // Still waiting, so it keeps its start.
            #expect(queued[second]?.pending == true)
            #expect(queued[second]?.pendingSince == start)
        }
    }
}
