// Tests/APITests/CourseLandingTests.swift
//
// The student dashboard's mixed-content sections: the presentation computed in
// `ContentItemRow`, the filter threshold on `IndexDisplayGroup`, the rendered
// row markup, and the inline PDF route.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct CourseLandingViewModelTests {

    private func item(
        kind: ContentItemKind = .document, description: String? = nil,
        links: [ContentLink] = [], attachments: [ContentAttachment] = [],
        updatedLabel: String? = nil
    ) -> APICourseContentItem {
        APICourseContentItem(
            id: UUID(), courseID: UUID(), sortOrder: 1, title: "Week 1", kind: kind,
            itemDescription: description, links: links, attachments: attachments,
            updatedLabel: updatedLabel)
    }

    private func attachment(_ name: String, label: String? = nil) -> ContentAttachment {
        ContentAttachment(
            id: UUID(), originalName: name, sizeBytes: 3_000_000, sortOrder: 1, label: label)
    }

    @Test func pdfAttachmentOpensInANewTab() throws {
        let row = ContentItemRow(from: item(attachments: [attachment("lecture-08.pdf")]))
        let action = try #require(row.actions.first)
        #expect(action.iconHref == "#i-eye")
        #expect(action.href.hasSuffix("/view"))
        #expect(action.opensNewTab)
        #expect(action.label.hasPrefix("Open lecture-08.pdf in a new tab ("))
        #expect(row.attachments.first?.viewURL == action.href)
    }

    @Test func nonPdfAttachmentDownloads() throws {
        let row = ContentItemRow(from: item(attachments: [attachment("data.csv")]))
        let action = try #require(row.actions.first)
        #expect(action.iconHref == "#i-download")
        #expect(!action.href.hasSuffix("/view"))
        #expect(!action.opensNewTab)
        #expect(action.label.hasPrefix("Download data.csv ("))
        #expect(row.attachments.first?.viewURL == nil)
    }

    @Test func pdfExtensionMatchIsCaseInsensitive() {
        let row = ContentItemRow(from: item(attachments: [attachment("Slides.PDF")]))
        #expect(row.attachments.first?.viewURL != nil)
    }

    @Test func linkActionsFollowAttachmentsAndPickTheirIcon() throws {
        let link = ContentLink(label: "Cheat sheet", url: "https://example.com/a")
        let row = ContentItemRow(
            from: item(links: [link], attachments: [attachment("a.pdf")]))
        #expect(row.actions.map(\.iconHref) == ["#i-eye", "#i-external"])
        #expect(row.actions.last?.label == "Open Cheat sheet")

        let notebook = ContentItemRow(from: item(kind: .notebook, links: [link]))
        #expect(notebook.actions.first?.iconHref == "#i-book")
        #expect(notebook.actions.first?.opensNewTab == true)
    }

    @Test func notebookLinkOnANonNotebookItemGetsTheBookIcon() {
        let links = [
            ContentLink(label: "PDF", url: "https://example.com/a.pdf"),
            ContentLink(label: "Jupyter Notebook", url: "https://example.com/a"),
        ]
        let row = ContentItemRow(from: item(kind: .slides, links: links))
        #expect(row.actions.map(\.iconHref) == ["#i-external", "#i-book"])
    }

    @Test func linkLabelStartingWithOpenIsNotDoubled() {
        let link = ContentLink(label: "open in JupyterHub", url: "https://example.com")
        let row = ContentItemRow(from: item(kind: .notebook, links: [link]))
        #expect(row.actions.first?.label == "open in JupyterHub")
    }

    @Test(arguments: [
        (ContentItemKind.slides, "#i-slides"), (.notebook, "#i-book"),
        (.document, "#i-file-text"), (.link, "#i-link"), (.outline, "#i-list"),
        (.heading, ""),
    ])
    func kindMapsToTileGlyph(kind: ContentItemKind, glyph: String) {
        #expect(ContentItemRow(from: item(kind: kind)).iconHref == glyph)
    }

    @Test func headingIsFlagged() {
        #expect(ContentItemRow(from: item(kind: .heading)).isHeading)
        #expect(!ContentItemRow(from: item(kind: .document)).isHeading)
    }

    @Test func detailsTextJoinsPartsAndSkipsEmpties() {
        let full = ContentItemRow(
            from: item(
                description: "Read before lab.", attachments: [attachment("a.pdf", label: "Notes")],
                updatedLabel: "Sep 3"))
        #expect(full.detailsText.hasPrefix("Updated Sep 3 · Notes, "))
        #expect(full.detailsText.hasSuffix(" · Read before lab."))
        #expect(ContentItemRow(from: item()).detailsText.isEmpty)
    }

    // MARK: - Filter threshold

    private func rows(_ count: Int) -> [IndexSectionItem] {
        (0..<count).map { _ in
            .material(ContentItemRow(from: item()))
        }
    }

    @Test func filterAppearsOnlyAtTheThreshold() {
        #expect(IndexDisplayGroup.filterThreshold == 8)
        #expect(!IndexDisplayGroup(name: "Labs", items: rows(7)).showFilter)
        #expect(IndexDisplayGroup(name: "Labs", items: rows(8)).showFilter)
    }

    @Test func ungroupedBucketNeverGetsAFilter() {
        #expect(!IndexDisplayGroup(name: nil, items: rows(30)).showFilter)
    }
}

@Suite(.serialized) final class CourseLandingRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-landing")
    }

    private func seedSection(materials: Int) async throws {
        let course = try await wrMakeCourse(on: app)
        let courseID = try course.requireID()
        let section = APICourseSection(name: "Week 1", sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        for index in 0..<materials {
            try await APICourseContentItem(
                courseID: courseID, sectionID: try section.requireID(), sortOrder: index,
                title: "Reading \(index)", kind: .document
            ).save(on: app.db)
        }
    }

    @Test func sectionOfSevenHasNoFilterAndOfEightDoes() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            try await seedSection(materials: 7)
            #expect(!(try await getHTML("/", cookie: cookie, on: app)).contains("filter-group"))
        }
    }

    @Test func eightRowSectionRendersFilterWithContract() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            try await seedSection(materials: 8)
            let html = try await getHTML("/", cookie: cookie, on: app)
            #expect(html.contains("filter-group"))
            #expect(html.contains("data-list-filter=\"assignments-0\""))
            #expect(html.contains("id=\"assignments-0\""))
            #expect(!html.contains("data-sort-initial"))
            #expect(!html.contains("sortable-table"))
        }
    }

    @Test func materialRowsUseTileAndActionCells() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            let course = try await wrMakeCourse(on: app)
            let courseID = try course.requireID()
            let itemID = UUID()
            let attachmentID = UUID()
            try await APICourseContentItem(
                id: itemID, courseID: courseID, sortOrder: 1, title: "Lecture 8", kind: .slides,
                links: [ContentLink(label: "Open in JupyterHub", url: "https://hub.example.com")],
                attachments: [
                    ContentAttachment(
                        id: attachmentID, originalName: "lecture-08.pdf", sizeBytes: 100,
                        sortOrder: 1),
                    ContentAttachment(
                        id: UUID(), originalName: "data.csv", sizeBytes: 100, sortOrder: 2),
                ]
            ).save(on: app.db)
            try await APICourseContentItem(
                courseID: courseID, sortOrder: 2, title: "Part Two", kind: .heading
            ).save(on: app.db)

            let html = try await getHTML("/", cookie: cookie, on: app)
            #expect(html.contains("data-kind=\"slides\""))
            #expect(html.contains("#i-slides"))
            #expect(html.contains("href=\"/content-files/\(itemID.uuidString)/\(attachmentID.uuidString)/view\""))
            #expect(html.contains("#i-eye"))
            #expect(html.contains("#i-download"))
            #expect(html.contains("#i-external"))
            #expect(html.contains("target=\"_blank\" rel=\"noopener noreferrer\""))
            #expect(html.contains("aria-label=\"Open in JupyterHub\""))
            #expect(!html.contains("Open Open"))
            #expect(html.contains("<td colspan=\"5\"><strong>Part Two</strong>"))
        }
    }

    // MARK: - Inline PDF route

    private func makeAttachment(
        name: String, bytes: Data, isPublished: Bool = true, closedCourse: Bool = false
    ) async throws -> (itemID: UUID, attachmentID: UUID) {
        let course: APICourse
        if closedCourse {
            course = APICourse(code: "LAND_CLOSED", name: "Closed", enrollmentMode: .closed)
            try await course.save(on: app.db)
        } else {
            course = try await wrMakeCourse(on: app)
        }
        let item = APICourseContentItem(
            courseID: try course.requireID(), sortOrder: 1, title: "Material", kind: .document,
            isPublished: isPublished)
        try await item.save(on: app.db)
        let itemID = try item.requireID()
        let request = Request(application: app, on: app.eventLoopGroup.any())
        let attachment = try await ContentAttachmentStore.store(
            bytes: bytes, originalName: name, label: nil, sortOrder: 1, itemID: itemID,
            on: request)
        item.attachments = [attachment]
        try await item.save(on: app.db)
        return (itemID, attachment.id)
    }

    /// Logs in the student and enrolls them in the seeded course.
    private func enrolledStudent() async throws -> String {
        let cookie = try await wrLoginAsStudent(on: app)
        try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
        return cookie
    }

    private func get(_ path: String, cookie: String) async throws -> (HTTPStatus, HTTPHeaders, String) {
        let res = try await getResponse(path, cookie: cookie, on: app)
        return (res.status, res.headers, res.body.string)
    }

    @Test func pdfIsServedInlineWithHardeningHeaders() async throws {
        try await withApp(app) { _ in
            let cookie = try await enrolledStudent()
            let ids = try await makeAttachment(name: "notes.pdf", bytes: Data("%PDF-1.7 body".utf8))
            let (status, headers, body) = try await get(
                "/content-files/\(ids.itemID)/\(ids.attachmentID)/view", cookie: cookie)
            #expect(status == .ok)
            #expect(body.hasPrefix("%PDF-"))
            #expect(headers.first(name: .contentType) == "application/pdf")
            #expect(headers.first(name: .contentDisposition) == "inline; filename=\"notes.pdf\"")
            #expect(headers.first(name: "X-Content-Type-Options") == "nosniff")
            #expect(headers.first(name: .cacheControl) == "private")
            #expect(headers.first(name: "Content-Security-Policy")?.contains("sandbox") != true)
        }
    }

    @Test func nonPdfIsNotFoundOnTheViewRoute() async throws {
        try await withApp(app) { _ in
            let cookie = try await enrolledStudent()
            let ids = try await makeAttachment(name: "data.csv", bytes: Data("a,b".utf8))
            let (status, _, _) = try await get(
                "/content-files/\(ids.itemID)/\(ids.attachmentID)/view", cookie: cookie)
            #expect(status == .notFound)
        }
    }

    @Test func pdfExtensionWithoutMagicBytesIsNotFound() async throws {
        try await withApp(app) { _ in
            let cookie = try await enrolledStudent()
            let ids = try await makeAttachment(
                name: "fake.pdf", bytes: Data("<html><script>1</script>".utf8))
            let (status, _, _) = try await get(
                "/content-files/\(ids.itemID)/\(ids.attachmentID)/view", cookie: cookie)
            #expect(status == .notFound)
        }
    }

    @Test func downloadRouteStillServesAnyTypeAsAttachment() async throws {
        try await withApp(app) { _ in
            let cookie = try await enrolledStudent()
            let ids = try await makeAttachment(name: "notes.pdf", bytes: Data("%PDF-1.7".utf8))
            let (status, headers, _) = try await get(
                "/content-files/\(ids.itemID)/\(ids.attachmentID)", cookie: cookie)
            #expect(status == .ok)
            #expect(headers.first(name: .contentDisposition)?.hasPrefix("attachment") == true)
        }
    }

    @Test func unenrolledCallerGetsTheSameStatusAsTheDownloadRoute() async throws {
        try await withApp(app) { _ in
            let cookie = try await enrolledStudent()
            let ids = try await makeAttachment(
                name: "notes.pdf", bytes: Data("%PDF-1.7".utf8), closedCourse: true)
            let base = "/content-files/\(ids.itemID)/\(ids.attachmentID)"
            let download = try await get(base, cookie: cookie)
            let view = try await get(base + "/view", cookie: cookie)
            #expect(view.0 == download.0)
            #expect(view.0 == .forbidden || view.0 == .notFound)
        }
    }

    @Test func draftPdfIsHiddenFromStudentsButOpenToStaff() async throws {
        try await withApp(app) { _ in
            let ids = try await makeAttachment(
                name: "notes.pdf", bytes: Data("%PDF-1.7".utf8), isPublished: false)
            let path = "/content-files/\(ids.itemID)/\(ids.attachmentID)/view"

            let student = try await enrolledStudent()
            #expect(try await get(path, cookie: student).0 == .notFound)

            let staff = try await wrLoginAsInstructor(on: app)
            try await wrEnrollUser(
                try #require(
                    try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()),
                on: app)
            #expect(try await get(path, cookie: staff).0 == .ok)
        }
    }
}
