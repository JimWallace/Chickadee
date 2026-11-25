// Tests/APITests/MCP/LectureNotebookToolsTests.swift
//
// Lecture notebooks over MCP (docs/lecture-notebooks.md): create_content_item
// and update_content_item with `lectureNotebook`, list_content_items'
// `lectureNotebook` object, and get_lecture_notebook.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct LectureNotebookToolsTests {

    private func notebook(_ markdown: String) -> JSONValue {
        .object([
            "nbformat": .int(4), "nbformat_minor": .int(5), "metadata": .object([:]),
            "cells": .array([
                .object([
                    "cell_type": .string("markdown"), "metadata": .object([:]),
                    "source": .array([.string(markdown)]),
                ])
            ]),
        ])
    }

    @Test func createListGetAndUpdateALectureNotebook() async throws {
        try await withTestApp { app in
            try await seedMCPCourse(on: app)
            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "Lecture 4", isPublished: false,
                    lectureNotebook: .init(language: "python", notebook: notebook("Lecture four examples"))),
                mcpContext(app))
            #expect(created.kind == "notebook")
            let lecture = try #require(created.lectureNotebook)
            #expect(lecture.language == "python")
            #expect(lecture.notebookPath.hasSuffix("/notebook"))
            #expect(lecture.editPath.hasSuffix("/notebook?edit=1"))

            let listed = try await ListContentItemsTool().execute(.init(courseCode: "CS246"), mcpContext(app))
            #expect(listed.contentItems.first?.lectureNotebook?.language == "python")

            let read = try await GetLectureNotebookTool().execute(
                .init(contentItemID: created.contentItemID), mcpContext(app))
            #expect(read.language == "python")
            #expect(read.cellCount == 1)
            #expect("\(read.notebook)".contains("Lecture four examples"))

            _ = try await UpdateContentItemTool().execute(
                .init(
                    contentItemID: created.contentItemID,
                    lectureNotebook: .init(notebook: notebook("Revised examples"))),
                mcpContext(app))
            let reread = try await GetLectureNotebookTool().execute(
                .init(contentItemID: created.contentItemID), mcpContext(app))
            #expect("\(reread.notebook)".contains("Revised examples"))

            // No assignment exists for the setup.
            #expect(try await APIAssignment.query(on: app.db).count() == 0)
        }
    }

    @Test func createRefusesAMissingOrEditorlessLanguage() async throws {
        try await withTestApp { app in
            try await seedMCPCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(courseCode: "CS246", title: "No language", lectureNotebook: .init()),
                    mcpContext(app))
            }
            for language in AssignmentLanguage.allCases where !LectureNotebookService.hasEditor(language) {
                await #expect(throws: MCPToolError.self) {
                    _ = try await CreateContentItemTool().execute(
                        .init(
                            courseCode: "CS246", title: "Upload-only",
                            lectureNotebook: .init(language: language.rawValue)),
                        mcpContext(app))
                }
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(
                        courseCode: "CS246", title: "Slides kind", kind: "slides",
                        lectureNotebook: .init(language: "python")),
                    mcpContext(app))
            }
            #expect(try await APICourseContentItem.query(on: app.db).count() == 0)
            #expect(try await APITestSetup.query(on: app.db).count() == 0)
        }
    }

    @Test func anOrdinaryItemCannotBecomeALectureNotebook() async throws {
        try await withTestApp { app in
            try await seedMCPCourse(on: app)
            let link = try await CreateContentItemTool().execute(
                .init(courseCode: "CS246", title: "A link", links: [.init(label: "Site", url: "https://example.com")]),
                mcpContext(app))
            #expect(link.lectureNotebook == nil)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateContentItemTool().execute(
                    .init(contentItemID: link.contentItemID, lectureNotebook: .init(language: "python")),
                    mcpContext(app))
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await GetLectureNotebookTool().execute(
                    .init(contentItemID: link.contentItemID), mcpContext(app))
            }
        }
    }
}
