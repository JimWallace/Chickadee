// Tests/APITests/InstructorOverviewTests.swift
//
// The instructor Overview (GET /instructor): the drag-and-drop markup contract
// that Public/section-items-dnd.js reads, the row menus, the state selects, and
// the material visibility route.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorOverviewTests {

    private struct VisibilityBody: Content {
        var isPublished: String
        var csrf: String
        enum CodingKeys: String, CodingKey {
            case isPublished
            case csrf = "_csrf"
        }
    }

    private func makeItem(
        courseID: UUID, sectionID: UUID? = nil, title: String = "Reading",
        kind: ContentItemKind = .document, isPublished: Bool = true
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: sectionID, sortOrder: 1, title: title, kind: kind,
            isPublished: isPublished)
        return item
    }

    private func overviewHTML(cookie: String, on app: Application) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    /// The text of the first `<tr …data-attr="value"…>` row, tag open to `</tr>`.
    private func row(containing marker: String, in html: String) throws -> String {
        let start = try #require(html.range(of: marker), "no row carrying \(marker)")
        let end = try #require(
            html.range(of: "</tr>", range: start.upperBound..<html.endIndex))
        return String(html[start.lowerBound..<end.upperBound])
    }

    // MARK: - Markup contract

    @Test func sectionTablesKeepTheDragAndDropContract() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let section = APICourseSection(name: "Labs", sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)
            let item = try await makeItem(courseID: courseID, sectionID: section.id)
            try await item.save(on: app.db)

            let html = try await overviewHTML(cookie: cookie, on: app)
            #expect(html.contains("<tbody data-section-id=\"\(try section.requireID().uuidString)\">"))
            #expect(html.contains("data-content-item-id=\"\(try item.requireID().uuidString)\""))
            #expect(html.contains("assignment-drag-handle"))
            #expect(html.contains("class=\"results-table section-items section-items--manage\""))
        }
    }

    @Test func publishedAssignmentRowOffersItsMenuAndStateSelect() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_ov_pub", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_ov_pub", title: "Lab Overview", isOpen: true,
                validationStatus: "passed", on: app)

            let html = try await overviewHTML(cookie: cookie, on: app)
            let row = try row(
                containing: "data-assignment-id=\"\(assignment.publicID)\"", in: html)
            #expect(row.contains("class=\"state-select\" data-state=\"open\""))
            #expect(row.contains("aria-label=\"More actions for Lab Overview\""))
            for action in ["clone", "retest", "delete"] {
                #expect(row.contains("action=\"/instructor/\(assignment.publicID)/\(action)\""))
            }
            // Delete is the last item and is marked destructive.
            let menu = try #require(row.range(of: "row-menu-item--danger"))
            #expect(row[menu.upperBound...].contains("Delete assignment"))
        }
    }

    @Test func failedValidationShowsAPillNotASelect() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_ov_fail", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_ov_fail", title: "Broken Lab", isOpen: false,
                validationStatus: "failed", on: app)

            let html = try await overviewHTML(cookie: cookie, on: app)
            let row = try row(
                containing: "data-assignment-id=\"\(assignment.publicID)\"", in: html)
            #expect(row.contains("Validation failed"))
            #expect(!row.contains("state-select"))
        }
    }

    @Test func materialRowHasVisibilitySelectAndDeleteInItsMenu() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let item = try await makeItem(courseID: courseID, title: "Secret Notes", isPublished: false)
            try await item.save(on: app.db)
            let itemID = try item.requireID().uuidString

            let html = try await overviewHTML(cookie: cookie, on: app)
            let row = try row(containing: "data-content-item-id=\"\(itemID)\"", in: html)
            #expect(row.contains("action=\"/instructor/content-items/\(itemID)/visibility\""))
            #expect(row.contains("class=\"state-select\" data-state=\"hidden\""))
            #expect(row.contains("aria-label=\"More actions for Secret Notes\""))
            #expect(row.contains("Delete material"))
        }
    }

    @Test func headingRowIsAFullWidthRowWithoutAStateSelect() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let item = try await makeItem(courseID: courseID, title: "Week Two", kind: .heading)
            try await item.save(on: app.db)

            let html = try await overviewHTML(cookie: cookie, on: app)
            let row = try row(
                containing: "data-content-item-id=\"\(try item.requireID().uuidString)\"", in: html)
            #expect(row.contains("section-items-heading"))
            #expect(row.contains("colspan=\"4\""))
            #expect(!row.contains("state-select"))
        }
    }

    @Test func addMenuOffersAssignmentAndEveryMaterialKind() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let section = APICourseSection(name: "Labs", sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)
            try await makeItem(courseID: courseID, sectionID: section.id).save(on: app.db)

            let html = try await overviewHTML(cookie: cookie, on: app)
            #expect(html.contains("href=\"/instructor/new?sectionID=\(try section.requireID().uuidString)\""))
            for kind in ["slides", "notebook", "document", "link", "outline", "heading"] {
                #expect(html.contains("data-add-kind=\"\(kind)\""), "missing + Add item for \(kind)")
            }
            #expect(!html.contains("+ Create New"))
            #expect(!html.contains("content-lane"))
        }
    }

    // MARK: - Visibility route

    private func postVisibility(
        itemID: UUID, value: String, cookie: String, on app: Application
    ) async throws -> HTTPStatus {
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        var status = HTTPStatus.internalServerError
        try await app.asyncTest(
            .POST, "/instructor/content-items/\(itemID)/visibility",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(
                    VisibilityBody(isPublished: value, csrf: token), as: .urlEncodedForm)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func instructorCanHideAndShowAMaterial() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let item = try await makeItem(courseID: courseID)
            try await item.save(on: app.db)
            let itemID = try item.requireID()

            #expect(try await postVisibility(itemID: itemID, value: "false", cookie: cookie, on: app) == .seeOther)
            #expect(try await APICourseContentItem.find(itemID, on: app.db)?.isPublished == false)
            #expect(try await postVisibility(itemID: itemID, value: "true", cookie: cookie, on: app) == .seeOther)
            #expect(try await APICourseContentItem.find(itemID, on: app.db)?.isPublished == true)
        }
    }

    @Test func aBadVisibilityValueIsRefusedAndChangesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let item = try await makeItem(courseID: courseID)
            try await item.save(on: app.db)
            let itemID = try item.requireID()

            let status = try await postVisibility(itemID: itemID, value: "maybe", cookie: cookie, on: app)
            #expect(status != .seeOther)
            #expect(try await APICourseContentItem.find(itemID, on: app.db)?.isPublished == true)
        }
    }

    @Test func studentCannotChangeVisibility() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let item = try await makeItem(courseID: courseID)
            try await item.save(on: app.db)
            let itemID = try item.requireID()
            let cookie = try await arLoginAsStudent(on: app)

            let status = try await postVisibility(itemID: itemID, value: "false", cookie: cookie, on: app)
            #expect(status != .seeOther)
            #expect(try await APICourseContentItem.find(itemID, on: app.db)?.isPublished == true)
        }
    }

    @Test func archivedCourseRefusesVisibilityChanges() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let item = try await makeItem(courseID: courseID)
            try await item.save(on: app.db)
            let itemID = try item.requireID()
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.isArchived = true
            try await course.save(on: app.db)

            let status = try await postVisibility(itemID: itemID, value: "false", cookie: cookie, on: app)
            #expect(status != .seeOther)
            #expect(try await APICourseContentItem.find(itemID, on: app.db)?.isPublished == true)
        }
    }
}
