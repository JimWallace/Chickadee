// Tests/APITests/Assignments/SectionPlacementTests.swift
//
// Where a new item goes in a course section, and what a move into a section
// does to the grading mode, on web and MCP alike (#2490).
//
// - Assignments and content items share one order per section. The content
//   item paths used to read only their own table, so a new content item in a
//   section of assignments got order 1 and sorted near the top. MCP
//   `create_assignment` and the clones left the order nil.
// - A move into a section adopts its default grading mode unless that would
//   break a manifest rule. The web move and the MCP tool used to restate three
//   of the rules each.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) final class SectionPlacementTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-section-placement")
    }

    private static let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

    @Test func aNewItemSortsAfterTheAssignmentsInItsSection() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "PLACE")
            let courseID = try course.requireID()
            let section = APICourseSection(name: "Labs", sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)
            let sectionID = try section.requireID()
            for order in 1...3 {
                try await makeTestSetup(on: app, id: "place_\(order)", courseID: courseID)
                try await APIAssignment(
                    testSetupID: "place_\(order)", title: "Lab \(order)", sortOrder: order,
                    sectionID: sectionID, courseID: courseID
                ).save(on: app.db)
            }

            #expect(try await nextSectionItemSortOrder(courseID: courseID, sectionID: sectionID, db: app.db) == 4)
            // The ungrouped lane is a lane of its own.
            #expect(try await nextSectionItemSortOrder(courseID: courseID, sectionID: nil, db: app.db) == 1)
        }
    }

    /// MCP `create_assignment` gives the new assignment an order after the
    /// ungrouped items already there, instead of nil.
    @Test func createAssignmentSetsTheOrder() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "PLACE2")
            let courseID = try course.requireID()
            try await APICourseContentItem(courseID: courseID, sortOrder: 5, title: "Reading")
                .save(on: app.db)

            let authored = try await AssignmentAuthoringService.createAssignment(
                courseID: courseID, title: "New Lab", language: .python, notebookData: Data(Self.notebook.utf8),
                setupsDirectory: app.testSetupsDirectory, on: app.db)

            #expect(authored.assignment.sortOrder == 6)
        }
    }

    /// A course, an Assignment-typed assignment on `manifest`, and a section
    /// whose default type is Lab.
    private func assignmentAndLabSection(
        manifest: String
    ) async throws -> (APIAssignment, APICourseSection) {
        let course = try await makeTestCourse(on: app, code: "MODE-\(UUID().uuidString.prefix(4))")
        let courseID = try course.requireID()
        let setup = try await makeTestSetup(
            on: app, id: "mode_\(UUID().uuidString.prefix(8))", courseID: courseID, manifest: manifest)
        let assignment = APIAssignment(
            testSetupID: try setup.requireID(), title: "Assignment 1", dueAt: nil, isOpen: false,
            courseID: courseID)
        assignment.assignmentType = .assignment
        try await assignment.save(on: app.db)
        let section = APICourseSection(
            name: "Labs", defaultAssignmentType: .lab, sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        return (assignment, section)
    }

    /// A move into a Lab-default section changes neither the type nor the
    /// grading mode (docs/assignment-types.md, phase 3). Before, it adopted the
    /// section's browser default and shipped an Assignment's secret tests to
    /// every student. The move reports the difference instead.
    @Test func aMoveChangesNeitherTheTypeNorTheGrading() async throws {
        try await withApp(app) { app in
            let (assignment, section) = try await assignmentAndLabSection(manifest: TestManifests.workerEmpty)
            let moved = try await CourseSectionService.moveAssignment(
                assignment, toSection: try section.requireID(), on: app.db)

            #expect(moved.gradingMode == "worker")
            let note = try #require(moved.typeNote)
            #expect(note.contains("an Assignment"))
            #expect(note.contains("a Lab"))
            let stored = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(stored.assignmentType == .assignment)
            #expect(stored.sectionID == section.id)
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode == .worker)
        }
    }

    /// No note when the types agree, or when the section names no default.
    @Test func aMoveReportsNothingWhenTheTypesAgree() async throws {
        try await withApp(app) { app in
            let (assignment, section) = try await assignmentAndLabSection(manifest: TestManifests.workerEmpty)
            assignment.assignmentType = .lab
            try await assignment.save(on: app.db)
            let moved = try await CourseSectionService.moveAssignment(
                assignment, toSection: try section.requireID(), on: app.db)
            #expect(moved.typeNote == nil)

            section.defaultAssignmentType = nil
            try await section.save(on: app.db)
            assignment.assignmentType = .assignment
            try await assignment.save(on: app.db)
            let again = try await CourseSectionService.moveAssignment(
                assignment, toSection: try section.requireID(), on: app.db)
            #expect(again.typeNote == nil)
        }
    }
}
