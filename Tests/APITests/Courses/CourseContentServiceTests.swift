// Tests/APITests/Courses/CourseContentServiceTests.swift
//
// The content-item rules that the web routes and the MCP tools share through
// `CourseContentService` (#2769), tested once at the service.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseContentServiceTests {

    private func draft(
        title: String = "Lecture 1", kind: String? = nil, links: [ContentLinkInput] = []
    ) throws(CourseContentError) -> ContentItemDraft {
        try ContentItemDraft(
            title: title, kind: kind, links: links, description: "  Intro  ", updatedLabel: "",
            isPublished: true)
    }

    // MARK: - Field rules

    @Test func draftTrimsTheTitleAndNormalizesTheTextFields() throws {
        let made = try draft(title: "  Lecture 1 ")
        #expect(made.title == "Lecture 1")
        #expect(made.itemDescription == "Intro")
        #expect(made.updatedLabel == nil)
    }

    @Test func aBlankTitleIsRefused() {
        #expect(throws: CourseContentError.emptyTitle) { _ = try draft(title: "   ") }
    }

    @Test func anAbsentKindIsALink() throws {
        #expect(try draft(kind: nil).kind == .link)
    }

    @Test(arguments: ContentItemKind.allCases)
    func everyKnownKindIsAccepted(kind: ContentItemKind) throws {
        #expect(try draft(kind: kind.rawValue).kind == kind)
    }

    @Test(arguments: ["video", "", "Link"])
    func anUnknownKindIsRefusedAndNotStoredAsALink(raw: String) {
        #expect(throws: CourseContentError.unknownKind(raw)) { _ = try draft(kind: raw) }
    }

    @Test func theUnknownKindReasonNamesEveryKind() {
        let reason = CourseContentError.unknownKind("video").description
        for kind in ContentItemKind.allCases {
            #expect(reason.contains(kind.rawValue))
        }
        #expect(CourseContentError.unknownKind("video").field == "kind")
    }

    @Test func linksDropBlankRowsAndDefaultTheLabelToTheURL() throws {
        let links = try CourseContentService.validatedLinks([
            ContentLinkInput(label: " PDF ", url: " https://example.com/a.pdf "),
            ContentLinkInput(label: "", url: ""),
            ContentLinkInput(label: nil, url: "/materials/a.ipynb"),
        ])
        #expect(
            links == [
                ContentLink(label: "PDF", url: "https://example.com/a.pdf"),
                ContentLink(label: "/materials/a.ipynb", url: "/materials/a.ipynb"),
            ])
    }

    @Test func aLinkWithALabelAndNoURLIsRefused() {
        #expect(throws: CourseContentError.linkMissingURL(label: "PDF")) {
            _ = try CourseContentService.validatedLinks([ContentLinkInput(label: "PDF", url: " ")])
        }
    }

    @Test(arguments: ["javascript:alert(1)", "data:text/html,x", "ftp://example.com/a"])
    func anUnsafeLinkURLIsRefused(url: String) {
        #expect(throws: CourseContentError.unsafeLinkURL(url)) {
            _ = try CourseContentService.validatedLinks([ContentLinkInput(label: "x", url: url)])
        }
    }

    @Test func aRefusedEditChangesNoField() {
        let item = APICourseContentItem(
            courseID: UUID(), sectionID: nil, sortOrder: 1, title: "Old", kind: .slides, links: [],
            isPublished: true)
        let edit = ContentItemEdit(title: "New", kind: "video", isPublished: false)
        #expect(throws: CourseContentError.unknownKind("video")) {
            try CourseContentService.apply(edit, to: item)
        }
        #expect(item.title == "Old")
        #expect(item.kind == .slides)
        #expect(item.isPublished)
    }

    @Test func anEditLeavesANilFieldUnchangedAndClearsAnEmptyText() throws {
        let item = APICourseContentItem(
            courseID: UUID(), sectionID: nil, sortOrder: 1, title: "Old", kind: .slides,
            itemDescription: "Keep me", links: [], updatedLabel: "2026-01-01", isPublished: true)
        try CourseContentService.apply(ContentItemEdit(updatedLabel: ""), to: item)
        #expect(item.title == "Old")
        #expect(item.kind == .slides)
        #expect(item.itemDescription == "Keep me")
        #expect(item.updatedLabel == nil)
        #expect(ContentItemEdit().isEmpty)
        #expect(!ContentItemEdit(isPublished: true).isEmpty)
    }

    // MARK: - Writes

    @Test func createAppendsToTheEndOfTheSectionLane() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CCS_CREATE").requireID()
            let first = try await CourseContentService.create(
                try draft(title: "One"), courseID: courseID, sectionID: nil, on: app.db)
            let second = try await CourseContentService.create(
                try draft(title: "Two", kind: "notebook"), courseID: courseID, sectionID: nil, on: app.db)
            #expect(second.sortOrder == first.sortOrder + 1)
            let stored = try #require(try await APICourseContentItem.find(second.id, on: app.db))
            #expect(stored.kind == .notebook)
            #expect(stored.title == "Two")
        }
    }

    @Test func updateMovesOnlyWhenTheSectionChanges() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CCS_UPDATE").requireID()
            let section = APICourseSection(
                name: "Week 1", defaultAssignmentType: .lab, sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)
            let sectionID = try section.requireID()
            let item = try await CourseContentService.create(
                try draft(), courseID: courseID, sectionID: nil, on: app.db)
            let order = item.sortOrder

            try await CourseContentService.update(
                item, with: ContentItemEdit(title: "Renamed"), movingTo: .some(nil), on: app.db)
            #expect(item.sortOrder == order)

            try await CourseContentService.update(
                item, with: ContentItemEdit(), movingTo: .some(sectionID), on: app.db)
            let stored = try #require(try await APICourseContentItem.find(item.id, on: app.db))
            #expect(stored.title == "Renamed")
            #expect(stored.sectionID == sectionID)
            #expect(stored.sortOrder == 1)
        }
    }

    @Test func aRefusedUpdateSavesNothing() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CCS_REFUSE").requireID()
            let item = try await CourseContentService.create(
                try draft(title: "Kept"), courseID: courseID, sectionID: nil, on: app.db)
            await #expect(throws: CourseContentError.unknownKind("video")) {
                try await CourseContentService.update(
                    item, with: ContentItemEdit(title: "Lost", kind: "video"), on: app.db)
            }
            let stored = try #require(try await APICourseContentItem.find(item.id, on: app.db))
            #expect(stored.title == "Kept")
            #expect(stored.kind == .link)
        }
    }

    @Test func deleteRemovesTheItem() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CCS_DELETE").requireID()
            let item = try await CourseContentService.create(
                try draft(), courseID: courseID, sectionID: nil, on: app.db)
            try await CourseContentService.delete(item, application: app, on: app.db)
            #expect(try await APICourseContentItem.find(item.id, on: app.db) == nil)
        }
    }
}
