// Tests/APITests/Courses/CourseSectionServiceTests.swift
//
// The course-section rules that the web routes and the MCP tools share through
// `CourseSectionService` (#2769), tested once at the service.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseSectionServiceTests {

    // MARK: - Field rules

    @Test func draftTrimsTheName() throws {
        let draft = try CourseSectionDraft(name: "  Labs ", defaultGradingMode: "worker")
        #expect(draft.name == "Labs")
        #expect(draft.defaultGradingMode == .worker)
    }

    @Test func aBlankNameIsRefused() {
        #expect(throws: CourseSectionError.emptyName) {
            _ = try CourseSectionDraft(name: "  ", defaultGradingMode: "browser")
        }
    }

    @Test(arguments: GradingMode.allCases)
    func everyGradingModeIsAccepted(mode: GradingMode) throws {
        #expect(try CourseSectionDraft(name: "Labs", defaultGradingMode: mode.rawValue).defaultGradingMode == mode)
    }

    @Test(arguments: ["", "Browser", "kernel"])
    func anUnknownGradingModeIsRefused(raw: String) {
        #expect(throws: CourseSectionError.unknownGradingMode(raw)) {
            _ = try CourseSectionDraft(name: "Labs", defaultGradingMode: raw)
        }
    }

    @Test func theGradingModeReasonNamesEveryMode() {
        let error = CourseSectionError.unknownGradingMode("kernel")
        for mode in GradingMode.allCases {
            #expect(error.description.contains(mode.rawValue))
        }
        #expect(error.field == "defaultGradingMode")
    }

    @Test func anEditValidatesOnlyTheFieldsItSets() throws {
        let edit = try CourseSectionEdit(name: nil, defaultGradingMode: "worker")
        #expect(edit.name == nil)
        #expect(edit.defaultGradingMode == .worker)
        #expect(throws: CourseSectionError.emptyName) {
            _ = try CourseSectionEdit(name: " ", defaultGradingMode: nil)
        }
    }

    // MARK: - Writes

    @Test func createAppendsAfterTheExistingSections() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_CREATE").requireID()
            let first = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs", defaultGradingMode: "browser"), courseID: courseID,
                on: app.db)
            let second = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Exams", defaultGradingMode: "worker"), courseID: courseID,
                on: app.db)
            #expect(second.sortOrder == first.sortOrder + 1)
            #expect(second.defaultGradingMode == "worker")
        }
    }

    @Test func updateChangesOnlyTheGivenFields() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_UPDATE").requireID()
            let section = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs", defaultGradingMode: "browser"), courseID: courseID,
                on: app.db)
            try await CourseSectionService.update(
                section, with: try CourseSectionEdit(name: nil, defaultGradingMode: "worker"), on: app.db)
            let stored = try #require(try await APICourseSection.find(section.id, on: app.db))
            #expect(stored.name == "Labs")
            #expect(stored.defaultGradingMode == "worker")
        }
    }

    @Test func deleteRemovesTheSection() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CSS_DELETE").requireID()
            let section = try await CourseSectionService.create(
                try CourseSectionDraft(name: "Labs", defaultGradingMode: "browser"), courseID: courseID,
                on: app.db)
            let ungrouped = try await CourseSectionService.delete(section, on: app.db)
            #expect(ungrouped == 0)
            #expect(try await APICourseSection.find(section.id, on: app.db) == nil)
        }
    }
}
