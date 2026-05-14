// Tests/APITests/AssignmentSeedStoreTests.swift
//
// Phase 1 of issue #461 — exercises the per-(user, assignment) seed store.

import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AssignmentSeedStoreTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configureTestDatabase(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
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

    func testEnsureSeed_createsRowOnFirstCall() async throws {
        let user = try await makeUser(username: "alice")
        let course = try await makeCourse()
        let assignment = try await makeAssignment(courseID: course.id!)

        let seed = try await AssignmentSeedStore.ensureSeed(
            userID: user.id!,
            assignmentID: assignment.id!,
            on: app.db
        )

        XCTAssertEqual(seed.count, 2 * AssignmentSeedStore.seedByteCount)
        XCTAssertTrue(seed.allSatisfy { "0123456789abcdef".contains($0) })

        let rows = try await APIAssignmentPersonalizationSeed.query(on: app.db).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].seedValue, seed)
    }

    func testEnsureSeed_isIdempotentForSamePair() async throws {
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

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        let rowCount = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
        XCTAssertEqual(rowCount, 1)
    }

    func testEnsureSeed_differentUsersGetDifferentSeeds() async throws {
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

        XCTAssertNotEqual(aliceSeed, bobSeed)
        let rowCount = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
        XCTAssertEqual(rowCount, 2)
    }

    func testEnsureSeed_differentAssignmentsGetDifferentSeeds() async throws {
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

        XCTAssertNotEqual(seed1, seed2)
    }

    func testEnsureSeed_survivesConcurrentFirstAccess() async throws {
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

        XCTAssertEqual(seeds.count, 3)
        XCTAssertEqual(Set(seeds).count, 1, "All concurrent ensureSeed calls must observe the same winner")
        let rowCount = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
        XCTAssertEqual(rowCount, 1, "UNIQUE(user_id, assignment_id) must collapse races to a single row")
    }

    func testGenerateSeedHex_isLowercaseHexOfExpectedLength() {
        for _ in 0..<32 {
            let seed = AssignmentSeedStore.generateSeedHex()
            XCTAssertEqual(seed.count, 2 * AssignmentSeedStore.seedByteCount)
            XCTAssertTrue(
                seed.allSatisfy { "0123456789abcdef".contains($0) },
                "seed must be lowercase hex; got \(seed)")
        }
    }
}
