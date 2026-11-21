// Tests/APITests/Courses/CourseBundleImportLinkTests.swift
//
// A bundled content item's links go through the same rule as a content item
// that the web form or MCP saves (`CourseContentService.validatedLinks`). The
// links render as `href`s for students, so a crafted bundle with a
// `javascript:` link is refused before anything is saved.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// A valid empty zip: the 22-byte end-of-central-directory record.
private let emptyZipBytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

@Suite(.serialized, .timeLimit(.minutes(10))) struct CourseBundleImportLinkTests {

    /// Writes an extracted bundle with one test setup, one assignment and one
    /// content item that holds `links` and one attachment. Returns the
    /// extract directory.
    private func writeExtractedBundle(
        root: URL, courseCode: String, itemTitle: String, links: [ContentLink]
    ) throws -> URL {
        let fm = FileManager.default
        let extractDir = root.appendingPathComponent("extract")
        try fm.createDirectory(
            at: extractDir.appendingPathComponent("testsetups"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: extractDir.appendingPathComponent("content"), withIntermediateDirectories: true)
        try Data(emptyZipBytes).write(to: extractDir.appendingPathComponent("testsetups/setup_cbl.zip"))
        let attachmentName = UUID().uuidString
        try Data("notes".utf8).write(to: extractDir.appendingPathComponent("content/\(attachmentName)"))

        let manifest = CourseBundleManifest(
            exportedAt: Date(),
            exportedBy: "test-admin",
            chickadeeVersion: "0.6.0",
            course: BundledCourse(code: courseCode, name: "Bundle Links"),
            users: [],
            enrolledUserBundleIDs: [],
            contentItems: [
                BundledContentItem(
                    sectionBundleID: nil, title: itemTitle, kind: "link", description: nil,
                    links: links,
                    attachments: [
                        BundledAttachment(
                            originalName: "notes.txt", sizeBytes: 5, label: nil, sortOrder: 0,
                            bundleFilename: "content/\(attachmentName)")
                    ],
                    updatedLabel: nil, isPublished: true, sortOrder: 1)
            ],
            assignments: [
                BundledAssignment(
                    bundleID: "assign_1", title: "Lab 1", dueAt: nil, isOpen: false, sortOrder: nil,
                    testSetupBundleID: "setup_1")
            ],
            testSetups: [
                BundledTestSetup(
                    bundleID: "setup_1", originalID: "setup_cbl", manifest: TestManifests.workerEmptyExplicit,
                    zipFilename: "testsetups/setup_cbl.zip")
            ],
            submissions: [],
            results: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: extractDir.appendingPathComponent("bundle.json"))
        return extractDir
    }

    private func directoryEntries(_ path: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
    }

    @Test(arguments: [
        ("CBLINKJS", "javascript:alert(document.cookie)"),
        ("CBLINKJSUPPER", "JavaScript:alert(1)"),
        ("CBLINKDATA", "data:text/html,<script>alert(1)</script>"),
        ("CBLINKPROTO", "//evil.example/phish"),
        ("CBLINKSLASH", "/\\evil.example/phish"),
        ("CBLINKNOURL", ""),
    ])
    func refusesAnUnsafeLink(courseCode: String, url: String) async throws {
        try await expectRefused(courseCode: courseCode, url: url)
    }

    private func expectRefused(courseCode: String, url: String) async throws {
        try await withTestApp { app in
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("cb-link-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let extractDir = try writeExtractedBundle(
                root: root, courseCode: courseCode, itemTitle: "Week 3 reading",
                links: [
                    ContentLink(label: "Slides", url: "https://example.edu/slides.pdf"),
                    ContentLink(label: "Bad", url: url),
                ])
            let setupsBefore = directoryEntries(app.testSetupsDirectory)
            let contentBefore = directoryEntries(app.contentFilesDirectory)
            let itemsBefore = try await APICourseContentItem.query(on: app.db).count()

            let error = await #expect(throws: AppError.self) {
                _ = try await CourseBundleService.importExtractedBundle(
                    extractDir: extractDir, app: app, db: app.db)
            }
            let message = String(describing: try #require(error))
            #expect(message.contains("Week 3 reading"))
            // A link with a label and no URL is named by its label.
            #expect(message.contains(url.isEmpty ? "\"Bad\"" : url))

            #expect(try await APICourse.query(on: app.db).filter(\.$code == courseCode).count() == 0)
            #expect(try await APICourseContentItem.query(on: app.db).count() == itemsBefore)
            #expect(directoryEntries(app.testSetupsDirectory) == setupsBefore)
            #expect(directoryEntries(app.contentFilesDirectory) == contentBefore)
        }
    }

    @Test func importsHttpHttpsAndSiteRelativeLinks() async throws {
        try await withTestApp { app in
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("cb-link-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let links = [
                ContentLink(label: "Plain", url: "http://example.edu/notes"),
                ContentLink(label: "Secure", url: "https://example.edu/slides.pdf"),
                ContentLink(label: "Local", url: "/site/path"),
            ]
            let extractDir = try writeExtractedBundle(
                root: root, courseCode: "CBLINKOK", itemTitle: "Week 4 reading", links: links)

            let tally = try await CourseBundleService.importExtractedBundle(
                extractDir: extractDir, app: app, db: app.db)

            let item = try #require(
                try await APICourseContentItem.query(on: app.db)
                    .filter(\.$courseID == tally.courseID).first())
            #expect(item.title == "Week 4 reading")
            #expect(item.links == links)
            #expect(item.attachments.count == 1)
        }
    }
}
