// Tests/APITests/Courses/CourseSectionServiceTests.swift
//
// The course-section rules that the web routes and the MCP tools share through
// `CourseSectionService` (#2769), tested once at the service. A section carries
// an optional default assignment type (docs/assignment-types.md, phase 3).

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseSectionServiceTests {

    // MARK: - Field rules

    @Test func draftTrimsTheName() throws {
        let draft = try CourseSectionDraft(name: "  Labs ", defaultAssignmentType: nil)
        #expect(draft.name == "Labs")
        #expect(draft.defaultAssignmentType == nil)
    }

    @Test func aBlankNameIsRefused() {
        #expect(throws: CourseSectionError.emptyName) {
            _ = try CourseSectionDraft(name: "  ", defaultAssignmentType: "lab")
        }
    }

    @Test(arguments: AssignmentType.allCases)
    func everyAssignmentTypeIsAccepted(type: AssignmentType) throws {
        #expect(
            try CourseSectionDraft(name: "Labs", defaultAssignmentType: type.rawValue).defaultAssignmentType == type)
    }

    @Test func anEmptyTypeMeansNoDefault() throws {
        #expect(try CourseSectionDraft(name: "Labs", defaultAssignmentType: "").defaultAssignmentType == nil)
    }

    @Test(arguments: ["Lab", "browser", "quiz"])
    func anUnknownTypeIsRefused(raw: String) {
        #expect(throws: CourseSectionError.unknownAssignmentType(raw)) {
            _ = try CourseSectionDraft(name: "Labs", defaultAssignmentType: raw)
        }
    }

    @Test func theTypeReasonNamesEveryType() {
        let error = CourseSectionError.unknownAssignmentType("quiz")
        for type in AssignmentType.allCases {
            #expect(error.description.contains(type.rawValue))
        }
        #expect(error.field == "defaultAssignmentType")
    }

    @Test func anEditValidatesOnlyTheFieldsItSets() throws {
        let edit = try CourseSectionEdit(name: nil, defaultAssignmentType: "lab")
        #expect(edit.name == nil)
        #expect(edit.defaultAssignmentType == .some(.lab))
        let untouched = try CourseSectionEdit(name: "Labs", defaultAssignmentType: nil)
        #expect(untouched.defaultAssignmentType == nil)
        let cleared = try CourseSectionEdit(name: nil, defaultAssignmentType: "")
        #expect(cleared.defaultAssignmentType == .some(nil))
        #expect(throws: CourseSectionError.emptyName) {
            _ = try CourseSectionEdit(name: " ", defaultAssignmentType: nil)
        }
    }

    // MARK: - Writes

    @Test func createAppendsAfterTheExistingSections() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_CREATE").requireID()
            let first = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs", defaultAssignmentType: "lab"), courseID: courseID,
                on: app.db)
            let second = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Exams", defaultAssignmentType: nil), courseID: courseID,
                on: app.db)
            #expect(second.sortOrder == first.sortOrder + 1)
            #expect(first.defaultAssignmentType == .lab)
            #expect(second.defaultAssignmentType == nil)
        }
    }

    @Test func updateChangesOnlyTheGivenFields() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_UPDATE").requireID()
            let section = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs", defaultAssignmentType: "lab"), courseID: courseID,
                on: app.db)
            try await CourseSectionService.update(
                section, with: try CourseSectionEdit(name: nil, defaultAssignmentType: "assignment"), on: app.db)
            var stored = try #require(try await APICourseSection.find(section.id, on: app.db))
            #expect(stored.name == "Labs")
            #expect(stored.defaultAssignmentType == .assignment)

            try await CourseSectionService.update(
                stored, with: try CourseSectionEdit(name: "Exams", defaultAssignmentType: nil), on: app.db)
            stored = try #require(try await APICourseSection.find(section.id, on: app.db))
            #expect(stored.name == "Exams")
            #expect(stored.defaultAssignmentType == .assignment)

            try await CourseSectionService.update(
                stored, with: try CourseSectionEdit(name: nil, defaultAssignmentType: ""), on: app.db)
            stored = try #require(try await APICourseSection.find(section.id, on: app.db))
            #expect(stored.defaultAssignmentType == nil)
        }
    }

    @Test func deleteRemovesTheSection() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_DELETE").requireID()
            let section = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs", defaultAssignmentType: "lab"), courseID: courseID,
                on: app.db)
            let ungrouped = try await CourseSectionService.delete(section, on: app.db)
            #expect(ungrouped == 0)
            #expect(try await APICourseSection.find(section.id, on: app.db) == nil)
        }
    }
}
