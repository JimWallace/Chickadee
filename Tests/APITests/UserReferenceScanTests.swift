// Tests/APITests/UserReferenceScanTests.swift
//
// Every column that names a user and declares no foreign key to `users` is
// either cleared by `AdminRoutes.deleteUser` or kept on purpose (#1808). The
// scan reads the `Create*` migrations, so a new such column fails here until
// it is classified; nothing else would notice a dangling UUID.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct UserReferenceScanTests {

    /// Cleared by `AdminRoutes.deleteUser` before the user row goes.
    static let clearedOnDelete: Set<String> = [
        "class_achievements.user_id",
        "submissions.retested_by_user_id",
        "tournament_runs.started_by",
        "tournament_runs.winner_user_id",
    ]

    /// Left as they are. Coverage never retreats when a student drops
    /// (docs/collaborative-class-assignments.md); a sync log is history; and
    /// a BrightSpace binding outlives the instructor who made it.
    static let keptOnPurpose: Set<String> = [
        "class_item_coverage.user_id",
        "brightspace_sync_log.user_id",
        "brightspace_credentials.user_id",
        "brightspace_credentials.captured_by_user_id",
        "courses.brightspace_sync_user_id",
    ]

    /// `table.column` for every `.uuid` column in a `Create*` migration whose
    /// name says it holds a user and that declares no reference to `users`.
    private static func userColumnsWithoutForeignKey() throws -> Set<String> {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let migrations = root.appendingPathComponent("Sources/APIServer/Migrations")
        let files = try FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Create") && $0.pathExtension == "swift" }
        let schema = try Regex(#"\.schema\("([a-z_]+)"\)"#)
        let call = try Regex(#"\.(field|unique|create|id)\("#)
        let quoted = try Regex(#""([a-z_]+)""#)
        var found: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let tables = source.matches(of: schema)
            for (index, table) in tables.enumerated() {
                let end = index + 1 < tables.count ? tables[index + 1].range.lowerBound : source.endIndex
                let chunk = source[table.range.upperBound..<end]
                let name = String(table.output[1].substring ?? "")
                let calls = chunk.matches(of: call)
                for (position, start) in calls.enumerated() where start.output[1].substring == "field" {
                    let pieceEnd = position + 1 < calls.count ? calls[position + 1].range.lowerBound : chunk.endIndex
                    let piece = chunk[start.range.upperBound..<pieceEnd]
                    guard let column = piece.firstMatch(of: quoted)?.output[1].substring,
                        piece.contains(".uuid"),
                        column.contains("user") || column.hasSuffix("_by"),
                        !piece.contains(#".references("users""#)
                    else { continue }
                    found.insert("\(name).\(column)")
                }
            }
        }
        return found
    }

    @Test func everyUserColumnWithoutAForeignKeyIsClearedOrKeptOnPurpose() throws {
        let found = try Self.userColumnsWithoutForeignKey()
        let expected = Self.clearedOnDelete.union(Self.keptOnPurpose)
        #expect(!found.isEmpty)
        #expect(
            found == expected,
            "new: \(found.subtracting(expected).sorted()); gone: \(expected.subtracting(found).sorted())")
    }

}

/// The columns the scan says are cleared really are cleared.
@Suite(.serialized) final class UserDeletionReferenceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-userref")
    }

    /// Deleting the user who started a tournament run and won it keeps the
    /// run and drops both attributions, as a retest attribution drops.
    @Test func deletingAUserClearsTheTournamentColumns() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(username: "ref_admin", password: "pass", role: "admin", on: app)
            let player = try await makeTestUser(on: app, username: "ref_player", role: "student")
            let playerID = try player.requireID()
            let course = try await makeTestCourse(on: app, code: "REF101")
            try await makeTestSetup(on: app, id: "ref_setup", courseID: try course.requireID())
            let run = try APITournamentRun(
                testSetupID: "ref_setup", schedule: .bracket, startedBy: playerID, startedAt: Date(),
                entrants: [])
            run.winnerUserID = playerID
            try await run.save(on: app.db)
            let runID = try run.requireID()

            let (token, boundCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/users/\(playerID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            let reloaded = try #require(try await APITournamentRun.find(runID, on: app.db))
            #expect(reloaded.startedBy == nil)
            #expect(reloaded.winnerUserID == nil)
            #expect(try await APIUser.find(playerID, on: app.db) == nil)
        }
    }
}
