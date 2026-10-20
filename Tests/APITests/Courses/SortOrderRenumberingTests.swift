// Tests/APITests/Courses/SortOrderRenumberingTests.swift
//
// The one course-wide reorder (#2713): `SortOrderRenumbering` holds the role
// floor, the duplicate rule, the unknown-type rule, the subset rule and the
// transaction for every reorder kind. The web routes and MCP tools that call
// it are pinned in `ReorderSurfaceRulesTests`.

import Core
import Fluent
import Foundation
import NIOCore
import Synchronization
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) final class SortOrderRenumberingTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-sort-order")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let courseID: UUID
        let sectionA: APICourseSection
        let sectionB: APICourseSection
        let labOne: APIAssignment
        let labTwo: APIAssignment
        let reading: APICourseContentItem
    }

    /// One course with two sections. Section A holds two labs (order 1, 2)
    /// and a reading (order 3).
    private func fixture(code: String = "SORT1") async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: code)
        let courseID = try course.requireID()
        let sectionA = APICourseSection(name: "A", defaultGradingMode: "worker", sortOrder: 1, courseID: courseID)
        try await sectionA.save(on: app.db)
        let sectionB = APICourseSection(name: "B", defaultGradingMode: "worker", sortOrder: 2, courseID: courseID)
        try await sectionB.save(on: app.db)
        let labOne = try await assignment(code + "_one", courseID: courseID, section: sectionA, order: 1)
        let labTwo = try await assignment(code + "_two", courseID: courseID, section: sectionA, order: 2)
        let reading = APICourseContentItem(
            courseID: courseID, sectionID: try sectionA.requireID(), sortOrder: 3, title: "Reading",
            kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")], isPublished: true)
        try await reading.save(on: app.db)
        return Fixture(
            courseID: courseID, sectionA: sectionA, sectionB: sectionB,
            labOne: labOne, labTwo: labTwo, reading: reading)
    }

    private func assignment(
        _ setupID: String, courseID: UUID, section: APICourseSection?, order: Int?
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: setupID)
        assignment.sectionID = try section?.requireID()
        assignment.sortOrder = order
        try await assignment.save(on: app.db)
        return assignment
    }

    private func order(of assignment: APIAssignment) async throws -> Int? {
        try #require(try await APIAssignment.find(assignment.id, on: app.db)).sortOrder
    }

    private func order(of item: APICourseContentItem) async throws -> Int {
        try #require(try await APICourseContentItem.find(item.id, on: app.db)).sortOrder
    }

    private func order(of section: APICourseSection) async throws -> Int {
        try #require(try await APICourseSection.find(section.id, on: app.db)).sortOrder
    }

    // MARK: - Role floor

    // These three tests read no database, but the suite's `app` must still
    // shut down, so each runs in `withApp`.

    @Test func theRoleFloorIsTAForEveryKind() async throws {
        try await withApp(app) { _ in
            #expect(SortOrderRenumbering.roleFloor == .ta)
        }
    }

    // MARK: - Parsing

    @Test func anUnknownTypeIsRefused() async throws {
        try await withApp(app) { _ in
            #expect(throws: ReorderError.unknownType("video")) {
                try SortOrderItem.parse(type: "video", id: "x")
            }
        }
    }

    @Test func aMalformedIDIsRefused() async throws {
        try await withApp(app) { _ in
            #expect(throws: ReorderError.invalidID("not-an-id!")) {
                try SortOrderItem.parse(type: "assignment", id: "not-an-id!")
            }
            #expect(throws: ReorderError.invalidID("nope")) {
                try SortOrderItem.parse(type: "content", id: "nope")
            }
            #expect(throws: ReorderError.invalidID("nope")) {
                try SortOrderRenumbering.sectionID("nope")
            }
        }
    }

    // MARK: - Section items

    @Test func sectionItemsAreRenumberedInTheGivenOrder() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let rows = try await SortOrderRenumbering.renumberSectionItems(
                [
                    .content(try fx.reading.requireID()),
                    .assignment(publicID: fx.labTwo.publicID),
                    .assignment(publicID: fx.labOne.publicID),
                ],
                inCourse: fx.courseID, on: app.db)
            #expect(rows.count == 3)
            #expect(try await order(of: fx.reading) == 1)
            #expect(try await order(of: fx.labTwo) == 2)
            #expect(try await order(of: fx.labOne) == 3)
        }
    }

    @Test func aDuplicateSectionItemIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            await #expect(throws: ReorderError.duplicateItem) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: fx.labOne.publicID), .assignment(publicID: fx.labOne.publicID)],
                    inCourse: fx.courseID, on: app.db)
            }
            #expect(try await order(of: fx.labOne) == 1)
        }
    }

    @Test func anItemOfAnotherCourseIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let other = try await fixture(code: "SORT2")
            await #expect(throws: ReorderError.unknownItem) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: other.labOne.publicID)],
                    inCourse: fx.courseID, on: app.db)
            }
            #expect(try await order(of: other.labOne) == 1)
        }
    }

    @Test func itemsOfTwoSectionsAreRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let elsewhere = try await assignment("SORT1_b", courseID: fx.courseID, section: fx.sectionB, order: 1)
            await #expect(throws: ReorderError.mixedSections) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: elsewhere.publicID), .assignment(publicID: fx.labOne.publicID)],
                    inCourse: fx.courseID, on: app.db)
            }
            #expect(try await order(of: fx.labOne) == 1)
        }
    }

    @Test func aSectionItemAndAnUngroupedItemAreRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let ungrouped = try await assignment("SORT1_u", courseID: fx.courseID, section: nil, order: 1)
            await #expect(throws: ReorderError.mixedSections) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: ungrouped.publicID), .content(try fx.reading.requireID())],
                    inCourse: fx.courseID, on: app.db)
            }
        }
    }

    @Test func anEmptyItemListWritesNothing() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let rows = try await SortOrderRenumbering.renumberSectionItems([], inCourse: fx.courseID, on: app.db)
            #expect(rows.isEmpty)
        }
    }

    @Test func owningCoursesNamesEveryCourseThePayloadTouches() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let other = try await fixture(code: "SORT3")
            let courses = try await SortOrderRenumbering.owningCourses(
                of: [.assignment(publicID: fx.labOne.publicID), .content(try other.reading.requireID())],
                on: app.db)
            #expect(courses == [fx.courseID, other.courseID])
        }
    }

    // MARK: - Course sections

    @Test func sectionsAreRenumberedInTheGivenOrder() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let rows = try await SortOrderRenumbering.renumberSections(
                [try fx.sectionB.requireID(), try fx.sectionA.requireID()], inCourse: fx.courseID, on: app.db)
            #expect(rows.map(\.name) == ["B", "A"])
            #expect(try await order(of: fx.sectionB) == 1)
            #expect(try await order(of: fx.sectionA) == 2)
        }
    }

    @Test func aSectionSubsetIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            await #expect(throws: ReorderError.incompleteList(expected: 2)) {
                _ = try await SortOrderRenumbering.renumberSections(
                    [try fx.sectionB.requireID()], inCourse: fx.courseID, on: app.db)
            }
            #expect(try await order(of: fx.sectionB) == 2)
        }
    }

    @Test func aDuplicateSectionIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let b = try fx.sectionB.requireID()
            await #expect(throws: ReorderError.duplicateItem) {
                _ = try await SortOrderRenumbering.renumberSections([b, b], inCourse: fx.courseID, on: app.db)
            }
        }
    }

    @Test func aSectionOfAnotherCourseIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let other = try await fixture(code: "SORT4")
            await #expect(throws: ReorderError.unknownItem) {
                _ = try await SortOrderRenumbering.renumberSections(
                    [try other.sectionA.requireID(), try fx.sectionA.requireID()],
                    inCourse: fx.courseID, on: app.db)
            }
        }
    }

    // MARK: - Transaction

    @Test func aFailedSectionItemWriteLeavesTheOldOrder() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let failing = FailingSecondUpdateDatabase(base: app.db)
            await #expect(throws: FailingSecondUpdateDatabase.UpdateRefused.self) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [
                        .content(try fx.reading.requireID()),
                        .assignment(publicID: fx.labOne.publicID),
                        .assignment(publicID: fx.labTwo.publicID),
                    ],
                    inCourse: fx.courseID, on: failing)
            }
            // The first write (the reading to 1) was rolled back.
            #expect(try await order(of: fx.reading) == 3)
            #expect(try await order(of: fx.labOne) == 1)
            #expect(try await order(of: fx.labTwo) == 2)
        }
    }

    @Test func aFailedAssignmentWriteLeavesTheOldOrder() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let failing = FailingSecondUpdateDatabase(base: app.db)
            await #expect(throws: FailingSecondUpdateDatabase.UpdateRefused.self) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: fx.labTwo.publicID), .assignment(publicID: fx.labOne.publicID)],
                    inCourse: fx.courseID, on: failing)
            }
            #expect(try await order(of: fx.labTwo) == 2)
            #expect(try await order(of: fx.labOne) == 1)
        }
    }

    @Test func aFailedContentItemWriteLeavesTheOldOrder() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let second = APICourseContentItem(
                courseID: fx.courseID, sectionID: try fx.sectionB.requireID(), sortOrder: 1, title: "Slides",
                kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")], isPublished: true)
            try await second.save(on: app.db)
            let third = APICourseContentItem(
                courseID: fx.courseID, sectionID: try fx.sectionB.requireID(), sortOrder: 2, title: "Notes",
                kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")], isPublished: true)
            try await third.save(on: app.db)
            let failing = FailingSecondUpdateDatabase(base: app.db)
            await #expect(throws: FailingSecondUpdateDatabase.UpdateRefused.self) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.content(try third.requireID()), .content(try second.requireID())],
                    inCourse: fx.courseID, on: failing)
            }
            #expect(try await order(of: third) == 2)
            #expect(try await order(of: second) == 1)
        }
    }

    @Test func aFailedSectionWriteLeavesTheOldOrder() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let failing = FailingSecondUpdateDatabase(base: app.db)
            await #expect(throws: FailingSecondUpdateDatabase.UpdateRefused.self) {
                _ = try await SortOrderRenumbering.renumberSections(
                    [try fx.sectionB.requireID(), try fx.sectionA.requireID()],
                    inCourse: fx.courseID, on: failing)
            }
            #expect(try await order(of: fx.sectionB) == 2)
            #expect(try await order(of: fx.sectionA) == 1)
        }
    }
}

/// Forwards every query to `base` and fails the second update, so a test can
/// make a reorder fail after its first write. The transaction it opens wraps
/// the transaction's connection the same way, so the count runs inside it.
private struct FailingSecondUpdateDatabase: Database {
    struct UpdateRefused: Error {}

    final class Counter: Sendable {
        let updates = Mutex(0)
    }

    let base: any Database
    let counter: Counter

    init(base: any Database, counter: Counter = Counter()) {
        self.base = base
        self.counter = counter
    }

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        if case .update = query.action {
            let count = counter.updates.withLock { value in
                value += 1
                return value
            }
            if count == 2 { return base.eventLoop.makeFailedFuture(UpdateRefused()) }
        }
        return base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { base.execute(schema: schema) }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { base.execute(enum: `enum`) }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let counter = counter
        return base.transaction { closure(FailingSecondUpdateDatabase(base: $0, counter: counter)) }
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let counter = counter
        return base.withConnection { closure(FailingSecondUpdateDatabase(base: $0, counter: counter)) }
    }
}
