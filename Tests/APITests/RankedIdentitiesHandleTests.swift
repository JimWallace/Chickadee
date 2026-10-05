// Tests/APITests/RankedIdentitiesHandleTests.swift
//
// A leaderboard's first view draws a handle for every ranked student who has
// none. `RankedIdentities.load` draws them all from one read of the course's
// taken handles (#2257), so the handles must still be distinct, and a handle
// already stored must stay.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class RankedIdentitiesHandleTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ranked-handles")
    }

    @Test func loadDrawsDistinctHandlesAndKeepsAStoredOne() async throws {
        try await withApp(app) { _ in
            let courseID = try await makeTestCourse(on: app, code: "RKH1").requireID()
            var userIDs: [UUID] = []
            for index in 0..<20 {
                let user = try await makeTestStudent(on: app, username: "rkh_\(index)")
                let userID = try user.requireID()
                _ = try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)
                userIDs.append(userID)
            }
            let named = try #require(
                try await APICourseEnrollment.query(on: app.db).filter(\.$userID == userIDs[0]).first())
            named.avatarHandle = "Quiet Cedar"
            try await named.save(on: app.db)

            _ = try await RankedIdentities.load(userIDs: userIDs, courseID: courseID, on: app.db)

            let handles = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID).all()
                .compactMap(\.avatarHandle)
            #expect(handles.count == 20)
            #expect(Set(handles).count == 20)
            #expect(handles.contains("Quiet Cedar"))
        }
    }
}
