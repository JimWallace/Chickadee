// Tests/APITests/AssignmentSeedStoreTests.swift
//
// Phase 1 of issue #461 — exercises the per-(user, assignment) seed store.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class AssignmentSeedStoreTests {

    let app: Application

    init() async throws {
        app = try await Application.make(.testing)
        try await configureTestDatabase(app)
    }

    // MARK: - Helpers

    private func makeUser(username: String) async throws -> APIUser {
        let user = APIUser(username: username, passwordHash: "x", role: "student")
        try await user.save(on: app.db)
        return user
    }

    private func makeAssignment(courseID: UUID) async throws -> APIAssignment {
        let setupID = UUID().uuidString
        // Insert a minimal test setup so the assignment FK is satisfiable.
        let testSetup = APITestSetup(
            id: setupID,
            manifest: "{}",
            zipPath: "/tmp/\(setupID).zip",
            courseID: courseID
        )
        try await testSetup.save(on: app.db)

        let assignment = APIAssignment(
            testSetupID: setupID,
            title: "Test Assignment \(setupID.prefix(6))",
            courseID: courseID
        )
        try await assignment.save(on: app.db)
        return assignment
    }

    private func makeCourse() async throws -> APICourse {
        let course = APICourse(code: "TEST-\(UUID().uuidString.prefix(6))", name: "Test Course")
        try await course.save(on: app.db)
        return course
    }

    // MARK: - Tests

    @Test func ensureSeed_createsRowOnFirstCall() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "alice")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: course.id!)

            let seed = try await AssignmentSeedStore.ensureSeed(
                userID: user.id!,
                assignmentID: assignment.id!,
                on: app.db
            )

            #expect(seed.count == 2 * AssignmentSeedStore.seedByteCount)
            #expect(seed.allSatisfy { "0123456789abcdef".contains($0) })

            let rows = try await APIAssignmentPersonalizationSeed.query(on: app.db).all()
            #expect(rows.count == 1)
            #expect(rows[0].seedValue == seed)

        }
    }

    @Test func ensureSeed_isIdempotentForSamePair() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "bob")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: course.id!)

            let first = try await AssignmentSeedStore.ensureSeed(
                userID: user.id!, assignmentID: assignment.id!, on: app.db
            )
            let second = try await AssignmentSeedStore.ensureSeed(
                userID: user.id!, assignmentID: assignment.id!, on: app.db
            )
            let third = try await AssignmentSeedStore.ensureSeed(
                userID: user.id!, assignmentID: assignment.id!, on: app.db
            )

            #expect(first == second)
            #expect(second == third)
            let rowCount = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
            #expect(rowCount == 1)

        }
    }

    @Test func ensureSeed_differentUsersGetDifferentSeeds() async throws {
        try await withApp(app) { _ in
            let alice = try await makeUser(username: "alice2")
            let bob = try await makeUser(username: "bob2")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: course.id!)

            let aliceSeed = try await AssignmentSeedStore.ensureSeed(
                userID: alice.id!, assignmentID: assignment.id!, on: app.db
            )
            let bobSeed = try await AssignmentSeedStore.ensureSeed(
                userID: bob.id!, assignmentID: assignment.id!, on: app.db
            )

            #expect(aliceSeed != bobSeed)
            let rowCount = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
            #expect(rowCount == 2)

        }
    }

    @Test func ensureSeed_differentAssignmentsGetDifferentSeeds() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "carol")
            let course = try await makeCourse()
            let a1 = try await makeAssignment(courseID: course.id!)
            let a2 = try await makeAssignment(courseID: course.id!)

            let seed1 = try await AssignmentSeedStore.ensureSeed(
                userID: user.id!, assignmentID: a1.id!, on: app.db
            )
            let seed2 = try await AssignmentSeedStore.ensureSeed(
                userID: user.id!, assignmentID: a2.id!, on: app.db
            )

            #expect(seed1 != seed2)

        }
    }

    @Test func ensureSeed_survivesConcurrentFirstAccess() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "dave")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: course.id!)
            let userID = user.id!
            let assignmentID = assignment.id!
            let db = app.db

            let seeds = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
                for _ in 0..<3 {
                    group.addTask {
                        try await AssignmentSeedStore.ensureSeed(
                            userID: userID, assignmentID: assignmentID, on: db
                        )
                    }
                }
                var collected: [String] = []
                for try await result in group { collected.append(result) }
                return collected
            }

            #expect(seeds.count == 3)
            #expect(Set(seeds).count == 1, "All concurrent ensureSeed calls must observe the same winner")
            let rowCount = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
            #expect(rowCount == 1, "UNIQUE(user_id, assignment_id) must collapse races to a single row")

        }
    }

    @Test func generateSeedHex_isLowercaseHexOfExpectedLength() async throws {
        try await withApp(app) { _ in
            for _ in 0..<32 {
                let seed = AssignmentSeedStore.generateSeedHex()
                #expect(seed.count == 2 * AssignmentSeedStore.seedByteCount)
                #expect(
                    seed.allSatisfy { "0123456789abcdef".contains($0) },
                    "seed must be lowercase hex; got \(seed)")
            }

        }
    }
}
