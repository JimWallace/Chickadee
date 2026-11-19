// Tests/APITests/Infrastructure/UniquenessIndexTests.swift
//
// The three "one row per X" rules that `CreateUniquenessIndexes` moved from
// app code into the database: one running tournament per setup and group,
// one BrightSpace credential per scope, one validation variant per setup and
// index. Each test checks the index refuses a second row, and that the app
// path the index guards still succeeds when it runs twice.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct UniquenessIndexTests {

    private func expectInsertConflict(
        _ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            try await body()
            #expect(Bool(false), "the second row was accepted", sourceLocation: sourceLocation)
        } catch {
            #expect(isInsertConflict(error), "not a unique violation: \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - tournament_runs

    @Test func aSecondRunningRunOfOneSetupAndGroupIsRefused() async throws {
        try await withTestApp(prefix: "chickadee-unique-tournament") { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await makeTestSetup(on: app, id: "setup_unique_cup", courseID: courseID)
            func run(group: UUID?, status: String = APITournamentRun.Status.running) throws -> APITournamentRun {
                let run = try APITournamentRun(
                    testSetupID: "setup_unique_cup", schedule: .bracket, startedBy: nil, startedAt: Date(),
                    entrants: [])
                run.groupID = group
                run.status = status
                return run
            }
            try await run(group: nil).save(on: app.db)
            await expectInsertConflict { try await run(group: nil).save(on: app.db) }

            // A finished or superseded run, and another group's run, are not
            // the running run of this scope.
            try await run(group: nil, status: APITournamentRun.Status.superseded).save(on: app.db)
            try await run(group: nil, status: APITournamentRun.Status.complete).save(on: app.db)
            let group = UUID()
            try await run(group: group).save(on: app.db)
            await expectInsertConflict { try await run(group: group).save(on: app.db) }
        }
    }

    // MARK: - brightspace_credentials

    @Test func oneCredentialPerScope() async throws {
        try await withTestApp(prefix: "chickadee-unique-brightspace") { app in
            let instructor = try await makeTestUser(on: app, username: "unique_bs_instructor")
            let instructorID = try instructor.requireID()

            // Saving twice, globally and for the instructor, replaces the row.
            for scope in [nil, instructorID] as [UUID?] {
                for key in ["first", "second"] {
                    try await BrightSpaceCredentialStore.save(
                        valenceUserID: "valence-\(key)", valenceUserKey: "key-\(key)", identityName: nil,
                        capturedByUserID: nil, userID: scope, on: app.db)
                }
            }
            let rows = try await APIBrightSpaceCredential.query(on: app.db).all()
            #expect(rows.count == 2)
            #expect(Set(rows.map(\.valenceUserID)) == ["valence-second"])

            // A row inserted beside the store is refused, the NULL scope included.
            for scope in [nil, instructorID] as [UUID?] {
                await expectInsertConflict {
                    try await APIBrightSpaceCredential(
                        valenceUserID: "valence-extra", valenceUserKey: "key-extra", identityName: nil,
                        capturedByUserID: nil, userID: scope
                    ).save(on: app.db)
                }
            }
        }
    }

    // MARK: - validation_variants

    @Test func aVariantWriteReplacesTheRowOfItsIndex() async throws {
        try await withTestApp(prefix: "chickadee-unique-variant") { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await makeTestSetup(on: app, id: "setup_unique_variant", courseID: courseID)
            let student = try await makeTestStudent(on: app, username: "unique_variant_student")
            for id in ["sub_variant_a", "sub_variant_b"] {
                try await makeTestSubmission(
                    on: app, id: id, setupID: "setup_unique_variant", userID: try student.requireID(),
                    kind: APISubmission.Kind.validation)
            }

            // Two overlapping validations each write index 0: the later wins.
            try await upsertValidationVariant(
                setupID: "setup_unique_variant", index: 0, seedHex: "aa", submissionID: "sub_variant_a", on: app.db)
            try await upsertValidationVariant(
                setupID: "setup_unique_variant", index: 0, seedHex: "bb", submissionID: "sub_variant_b", on: app.db)
            let rows = try await ValidationVariant.query(on: app.db)
                .filter(\.$testSetupID == "setup_unique_variant").all()
            #expect(rows.count == 1)
            #expect(rows.first?.submissionID == "sub_variant_b")
            #expect(rows.first?.seedHex == "bb")
            #expect(rows.first?.status == ValidationVariant.Status.pending)

            await expectInsertConflict {
                try await ValidationVariant(
                    testSetupID: "setup_unique_variant", variantIndex: 0, seedHex: "cc", submissionID: nil
                ).save(on: app.db)
            }
        }
    }
}
