// Tests/APITests/SectionPlacementTests.swift
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
                courseID: courseID, title: "New Lab", notebookData: Data(Self.notebook.utf8),
                setupsDirectory: app.testSetupsDirectory, on: app.db)

            #expect(authored.assignment.sortOrder == 6)
        }
    }

    private func setupAndSection(
        manifest: String, sectionMode: GradingMode
    ) async throws -> (APITestSetup, APICourseSection) {
        let course = try await makeTestCourse(on: app, code: "MODE-\(UUID().uuidString.prefix(4))")
        let courseID = try course.requireID()
        let setup = try await makeTestSetup(
            on: app, id: "mode_\(UUID().uuidString.prefix(8))", courseID: courseID, manifest: manifest)
        let section = APICourseSection(
            name: "Labs", defaultGradingMode: sectionMode.rawValue, sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        return (setup, section)
    }

    @Test func aMoveAdoptsTheSectionsGradingMode() async throws {
        try await withApp(app) { app in
            let (setup, section) = try await setupAndSection(
                manifest: #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#,
                sectionMode: .browser)
            #expect(try await adoptSectionGradingMode(section, setup: setup, on: app.db) == "browser")
            #expect(setup.decodedManifest()?.gradingMode == .browser)
        }
    }

    /// Browser grading would break a manifest rule here, so the setup keeps
    /// worker grading and the move does not fail.
    @Test(arguments: [
        #"{"schemaVersion":1,"gradingMode":"worker","submissionMode":"uploadOnly","testSuites":[],"timeLimitSeconds":10}"#,
        #"{"schemaVersion":1,"gradingMode":"worker","graderOnlyFiles":["answers.csv"],"testSuites":[],"timeLimitSeconds":10}"#,
    ])
    func aMoveKeepsWorkerGradingWhenBrowserWouldBeIncoherent(_ manifest: String) async throws {
        try await withApp(app) { app in
            let (setup, section) = try await setupAndSection(manifest: manifest, sectionMode: .browser)
            #expect(try await adoptSectionGradingMode(section, setup: setup, on: app.db) == "worker")
            #expect(setup.decodedManifest()?.gradingMode == .worker)
        }
    }
}
