// Tests for the LTI record reaper: expired or consumed login states and
// deep-link requests are deleted, while live ones are preserved.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LTIRecordReaperTests {
    @Test func reapsDeadLoginStatesAndDeepLinkRequestsKeepsLiveOnes() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let now = Date()
            let platform = APILTIPlatform(
                issuer: "https://lms.example.edu", clientID: "client", deploymentIDs: ["d1"],
                authLoginURL: "https://lms.example.edu/auth", accessTokenURL: "https://lms.example.edu/token",
                jwksURL: "https://lms.example.edu/jwks", displayName: "LMS")
            try await platform.save(on: app.db)
            let platformID = try platform.requireID()
            let courseID = try await app.testCourseID()
            let userID = try await makeTestUser(on: app, username: "lti-reaper-subject").requireID()

            // Login states: expired, consumed, and live.
            for (hash, expiresAt, consumed) in [
                ("state-expired", now.addingTimeInterval(-60), false),
                ("state-consumed", now.addingTimeInterval(60), true),
                ("state-live", now.addingTimeInterval(60), false),
            ] {
                let state = APILTILoginState(
                    stateHash: hash, nonce: "n", platformID: platformID, expiresAt: expiresAt)
                state.consumed = consumed
                try await state.save(on: app.db)
            }

            // Deep-link requests: expired, consumed, and live.
            let pending = LTIPendingDeepLink(
                returnURL: "https://lms.example.edu/return", data: nil, deploymentID: "d1", acceptMultiple: false)
            for (hash, expiresAt, consumed) in [
                ("ticket-expired", now.addingTimeInterval(-60), false),
                ("ticket-consumed", now.addingTimeInterval(60), true),
                ("ticket-live", now.addingTimeInterval(60), false),
            ] {
                let request = APILTIDeepLinkRequest(
                    ticketHash: hash, platformID: platformID, courseID: courseID, userID: userID,
                    request: pending, expiresAt: expiresAt)
                request.consumed = consumed
                try await request.save(on: app.db)
            }

            try await reapExpiredLTIRecords(on: app.db, logger: app.logger, now: now)

            let stateHashes = try await APILTILoginState.query(on: app.db).all().map(\.stateHash)
            #expect(stateHashes == ["state-live"])
            let ticketHashes = try await APILTIDeepLinkRequest.query(on: app.db).all().map(\.ticketHash)
            #expect(ticketHashes == ["ticket-live"])
        }
    }
}
