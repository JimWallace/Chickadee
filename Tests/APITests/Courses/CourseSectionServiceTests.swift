// Tests/APITests/Courses/CourseSectionServiceTests.swift
//
// The course-section rules that the web routes and the MCP tools share through
// `CourseSectionService` (#2769), tested once at the service. A section carries
// only a name: no grading mode and no type (docs/assignment-types.md).

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseSectionServiceTests {

    // MARK: - Field rules

    @Test func draftTrimsTheName() throws {
        #expect(try CourseSectionDraft(name: "  Labs ").name == "Labs")
        #expect(try CourseSectionEdit(name: " Exams").name == "Exams")
    }

    @Test func aBlankNameIsRefused() {
        #expect(throws: CourseSectionError.emptyName) {
            _ = try CourseSectionDraft(name: "  ")
        }
        #expect(throws: CourseSectionError.emptyName) {
            _ = try CourseSectionEdit(name: " ")
        }
    }

    // MARK: - Writes

    @Test func createAppendsAfterTheExistingSections() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_CREATE").requireID()
            let first = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs"), courseID: courseID, on: app.db)
            let second = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Exams"), courseID: courseID, on: app.db)
            #expect(second.sortOrder == first.sortOrder + 1)
        }
    }

    @Test func updateRenames() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_UPDATE").requireID()
            let section = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs"), courseID: courseID, on: app.db)
            try await CourseSectionService.update(section, with: try CourseSectionEdit(name: "Exams"), on: app.db)
            let stored = try #require(try await APICourseSection.find(section.id, on: app.db))
            #expect(stored.name == "Exams")
        }
    }

    @Test func deleteRemovesTheSection() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_DELETE").requireID()
            let section = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs"), courseID: courseID, on: app.db)
            let ungrouped = try await CourseSectionService.delete(section, on: app.db)
            #expect(ungrouped == 0)
            #expect(try await APICourseSection.find(section.id, on: app.db) == nil)
        }
    }
}
