// Tests/APITests/Courses/CourseBundleRoundTripTests.swift
//
// Integration tests that export a course bundle and import it again:
//
//   GET  /admin/courses/:courseID/export  — stream a bundle ZIP (admin only)
//   POST /admin/courses/import            — accept an uploaded bundle ZIP (admin only)
//
// Closes #69 and #70.
//
// Split out of the former CourseBundleTests.swift; the shared fixtures are in
// CourseBundleRouteFixtures.swift.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleRoundTripTests: CourseBundleRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtest-roundtrip")
    }

    // MARK: - Round-trip: export → import

    @Test func roundTripExportImport() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            // Set up source course
            let course = try await makeTestCourse(code: "ROUNDTRIP_CB")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_rt_cb1", courseID: courseID)
            try await insertAssignment(testSetupID: (try setup.requireID()), title: "RT Lab", courseID: courseID)

            // Export
            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                }
            )
            #expect(exportedZip.isEmpty == false, "Exported ZIP should not be empty")

            // Archive the original so the import does not hit a 409
            course.isArchived = true
            try await course.save(on: app.db)

            // Import the exported ZIP
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "Import should not fail: \(body.prefix(300))")
            #expect(status != .conflict, "\(body)")
            #expect(status != .forbidden, "\(body)")

            // Verify the imported course has the same structure
            guard
                let imported = try await APICourse.query(on: app.db)
                    .filter(\.$code == "ROUNDTRIP_CB")
                    .filter(\.$isArchived == false)
                    .first()
            else {
                Issue.record("Imported course should exist and be active")
                return
            }
            let importedID = try imported.requireID()
            let importedSetups = try await APITestSetup.query(on: app.db)
                .filter(\.$courseID == importedID).all()
            #expect(importedSetups.count == 1, "Round-trip: expected 1 test setup")

            let importedAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == importedID).all()
            #expect(importedAssignments.count == 1, "Round-trip: expected 1 assignment")
            #expect(importedAssignments.first?.title == "RT Lab")

        }
    }

    /// The bundle carries the four per-assignment policies, the dates, the
    /// open state and the course authoring guide as they were (#1737).
    @Test func roundTripPreservesAssignmentPoliciesAndTheGuide() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "POLICY_RT")
            course.mcpInstructions = "Write every hint as one sentence."
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_policy_rt", courseID: courseID)
            let assignment = try await insertAssignment(testSetupID: try setup.requireID(), courseID: courseID)
            let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
            assignment.dueAt = dueAt
            assignment.visibility = .open
            assignment.secretRevealEnabled = true
            assignment.passingThresholdPercent = 70
            assignment.solutionVisibility = .afterDue
            assignment.brightspaceSyncExcluded = true
            try await assignment.save(on: app.db)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "POLICY_RT")
                    .filter(\.$isArchived == false)
                    .first())
            #expect(imported.mcpInstructions == "Write every hint as one sentence.")
            let importedAssignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let importedDueAt = try #require(importedAssignment.dueAt)
            #expect(abs(importedDueAt.timeIntervalSince(dueAt)) < 1)
            #expect(importedAssignment.visibility == .open)
            #expect(importedAssignment.secretRevealEnabled == true)
            #expect(importedAssignment.passingThresholdPercent == 70)
            #expect(importedAssignment.solutionVisibility == .afterDue)
            #expect(importedAssignment.brightspaceSyncExcluded == true)
        }
    }

    /// The bundle carries the deadline override with the open state it
    /// protects, so the deadline sweep leaves an imported assignment open
    /// past its due date, as it was (#2166).
    @Test func roundTripPreservesTheDeadlineOverride() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "OVERRIDE_RT")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_override_rt", courseID: courseID)
            let assignment = try await insertAssignment(testSetupID: try setup.requireID(), courseID: courseID)
            assignment.dueAt = Date(timeIntervalSince1970: 1_600_000_000)
            assignment.visibility = .open
            assignment.deadlineOverrideActive = true
            try await assignment.save(on: app.db)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let closed = try await closeExpiredAssignments(on: app.db, logger: app.logger)
            #expect(closed == 0)
            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "OVERRIDE_RT")
                    .filter(\.$isArchived == false)
                    .first())
            let importedAssignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            #expect(importedAssignment.deadlineOverrideActive == true)
            #expect(importedAssignment.visibility == .open)
        }
    }

    /// The bundle course row carries the term, the enrollment mode and the
    /// four slip-day fields through export and import (#2171). The Core
    /// tests pin the resolvers; this pins the route on both sides.
    @Test func roundTripPreservesTermEnrollmentModeAndSlipDayPolicy() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = APICourse(
                code: "TERM_RT", name: "Term Round Trip", enrollmentMode: .auto,
                term: AcademicTerm(year: 2026, season: .fall))
            course.slipDaysEnabled = true
            course.slipDaysPerStudent = 4
            course.slipDayExtensionHours = 36
            course.slipDayReleaseRevealHold = false
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "TERM_RT")
                    .filter(\.$isArchived == false)
                    .first())
            #expect(imported.term?.year == 2026)
            #expect(imported.term?.season == .fall)
            #expect(imported.enrollmentMode == .auto)
            #expect(imported.slipDaysEnabled == true)
            #expect(imported.slipDaysPerStudent == 4)
            #expect(imported.slipDayExtensionHours == 36)
            #expect(imported.slipDayReleaseRevealHold == false)
        }
    }

    /// The bundle carries the runner requirements an assignment declared,
    /// and import writes them as the imported assignment's row (#2167).
    @Test func roundTripPreservesTheAssignmentRequirement() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "REQ_RT")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_req_rt", courseID: courseID)
            let assignment = try await insertAssignment(testSetupID: try setup.requireID(), courseID: courseID)
            let spec = AssignmentRequirementSpec(
                requiredPlatform: "linux", requiredArchitecture: "arm64",
                requiredLanguages: [AssignmentLanguageRequirement(language: "r", exactVersion: "4.3")],
                requiredCapabilities: [RunnerCapability(name: "tidyverse")])
            try await AssignmentRequirement(assignmentID: try assignment.requireID(), specification: spec)
                .save(on: app.db)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "REQ_RT")
                    .filter(\.$isArchived == false)
                    .first())
            let importedAssignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let copied = try #require(
                try await AssignmentRequirement.query(on: app.db)
                    .filter(\.$assignmentID == (try importedAssignment.requireID()))
                    .first())
            #expect(copied.requirementSpec == spec)
        }
    }

    /// Staff round-trip as staff: the bundle carries each enrollment's course
    /// role, and import enrolls the matched user in that role (#1740).
    @Test func roundTripPreservesEnrollmentRoles() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "ROLES_RT")
            let courseID = try course.requireID()
            let hash = try testPasswordHash("roles-pw")
            let expected: [(username: String, role: CourseRole)] = [
                ("cb_roles_student", .student), ("cb_roles_ta", .ta), ("cb_roles_instructor", .instructor),
            ]
            for entry in expected {
                let user = APIUser(username: entry.username, passwordHash: hash, role: "user")
                try await user.save(on: app.db)
                try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: entry.role)
                    .save(on: app.db)
            }

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in exportedZip = Data(res.body.readableBytesView) }
            )
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "ROLES_RT")
                    .filter(\.$isArchived == false)
                    .first())
            let importedID = try imported.requireID()
            for entry in expected {
                let user = try #require(
                    try await APIUser.query(on: app.db).filter(\.$username == entry.username).first())
                let enrollment = try #require(
                    try await APICourseEnrollment.query(on: app.db)
                        .filter(\.$course.$id == importedID)
                        .filter(\.$userID == (try user.requireID()))
                        .first())
                #expect(enrollment.role == entry.role, "\(entry.username) should round-trip as \(entry.role)")
            }
        }
    }

    /// A bundle from before the per-course roles names a user's deployment
    /// role in the old vocabulary. The importer reads it as a plain user
    /// rather than writing that word into `users.role` (#1740).
    @Test func importReadsALegacyUserRoleAsUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let zipData = try await makeBundleZipWithUser(
                courseCode: "LEGACYROLE_CB", username: "cb_legacy_role_user")
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "\(body)")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "cb_legacy_role_user").first())
            #expect(user.role == UserRole.user.rawValue)
        }
    }

    // MARK: - Round-trip: sections preserved through export → import

    @Test func roundTripPreservesSections() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            let course = try await makeTestCourse(code: "RT_SECTS")
            let courseID = try course.requireID()

            // Two sections.
            let browserSec = APICourseSection(
                name: "Browser Labs", sortOrder: 1, courseID: courseID)
            try await browserSec.save(on: app.db)
            let workerSec = APICourseSection(
                name: "Worker Labs", sortOrder: 2, courseID: courseID)
            try await workerSec.save(on: app.db)

            let setup1 = try await insertSetupWithZip(id: "rt_sects_s1", courseID: courseID)
            let setup2 = try await insertSetupWithZip(id: "rt_sects_s2", courseID: courseID)

            let a1 = APIAssignment(
                testSetupID: try #require(setup1.id), title: "Browser Lab",
                visibility: .closed, sectionID: try browserSec.requireID(),
                courseID: courseID)
            try await a1.save(on: app.db)
            let a2 = APIAssignment(
                testSetupID: try #require(setup2.id), title: "Worker Lab",
                visibility: .closed, sectionID: try workerSec.requireID(),
                courseID: courseID)
            try await a2.save(on: app.db)

            // Export.
            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })
            #expect(!exportedZip.isEmpty)

            // Inspect the raw manifest to confirm sections + sectionBundleIDs.
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-sects-ext-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            let zipVerifyPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-sects-\(UUID().uuidString).zip").path
            defer { try? FileManager.default.removeItem(atPath: zipVerifyPath) }
            try exportedZip.write(to: URL(fileURLWithPath: zipVerifyPath))
            try await extractZipArchive(zipPath: zipVerifyPath, into: extractDir)

            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)

            #expect(manifest.sections?.count == 2, "Manifest should include 2 sections")
            #expect(
                manifest.assignments.allSatisfy { $0.sectionBundleID != nil },
                "Every assignment in the manifest should carry a sectionBundleID")

            // Archive the original so import doesn't collide.
            course.isArchived = true
            try await course.save(on: app.db)

            // Import.
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "Import should not fail: \(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_SECTS")
                    .filter(\.$isArchived == false)
                    .first(),
                "Imported course not found")
            let importedID = try imported.requireID()

            // Sections recreated with correct names, in order.
            let importedSections = try await APICourseSection.query(on: app.db)
                .filter(\.$courseID == importedID)
                .sort(\.$sortOrder)
                .all()
            #expect(importedSections.count == 2, "Imported course should have 2 sections")
            #expect(importedSections.first?.name == "Browser Labs")
            #expect(importedSections.last?.name == "Worker Labs")

            // All assignments placed in a section, not ungrouped.
            let importedAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == importedID)
                .all()
            #expect(importedAssignments.count == 2)
            #expect(
                importedAssignments.allSatisfy { $0.sectionID != nil },
                "All imported assignments should have a sectionID")
        }
    }

    // MARK: - Round-trip: content items preserved through export → import

    @Test func roundTripPreservesContentItems() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "RT_CONTENT")
            let courseID = try course.requireID()

            let section = APICourseSection(
                name: "Lectures", sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)

            // One sectioned item (two links) + one ungrouped, hidden item.
            let sectioned = APICourseContentItem(
                courseID: courseID, sectionID: try section.requireID(), sortOrder: 1,
                title: "Lecture 1", kind: .notebook, itemDescription: "Intro",
                links: [
                    ContentLink(label: "PDF", url: "https://example.com/l1.pdf"),
                    ContentLink(label: "NB", url: "/materials/l1.ipynb"),
                ],
                updatedLabel: "2026-05-11", isPublished: true)
            try await sectioned.save(on: app.db)
            let ungrouped = APICourseContentItem(
                courseID: courseID, sectionID: nil, sortOrder: 1, title: "Outline",
                kind: .outline, links: [ContentLink(label: "Link", url: "https://example.com/o")],
                isPublished: false)
            try await ungrouped.save(on: app.db)

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })

            // Inspect the raw manifest.
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-content-ext-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            let zipVerifyPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-content-\(UUID().uuidString).zip").path
            defer { try? FileManager.default.removeItem(atPath: zipVerifyPath) }
            try exportedZip.write(to: URL(fileURLWithPath: zipVerifyPath))
            try await extractZipArchive(zipPath: zipVerifyPath, into: extractDir)
            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)
            #expect(manifest.contentItems?.count == 2)
            let bundledSectioned = try #require(manifest.contentItems?.first { $0.title == "Lecture 1" })
            #expect(bundledSectioned.sectionBundleID != nil)
            #expect(bundledSectioned.links.count == 2)
            let bundledUngrouped = try #require(manifest.contentItems?.first { $0.title == "Outline" })
            #expect(bundledUngrouped.sectionBundleID == nil)
            #expect(bundledUngrouped.isPublished == false)

            // Archive + import into a fresh course.
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "\(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_CONTENT").filter(\.$isArchived == false).first())
            let importedItems = try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == imported.requireID()).sort(\.$sortOrder).all()
            #expect(importedItems.count == 2)
            let importedSectioned = try #require(importedItems.first { $0.title == "Lecture 1" })
            #expect(importedSectioned.sectionID != nil, "sectioned item should keep its section link")
            #expect(importedSectioned.links.count == 2)
            #expect(importedSectioned.kind == .notebook)
            let importedUngrouped = try #require(importedItems.first { $0.title == "Outline" })
            #expect(importedUngrouped.sectionID == nil)
            #expect(importedUngrouped.isPublished == false)
        }
    }

    /// A content item attached to an assignment is attached, after the
    /// import, to the imported copy of that assignment, not to the source
    /// assignment. An item with no assignment stays standalone.
    @Test func roundTripReattachesMaterialToTheImportedAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "RT_SHOW_ON")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_rt_show_on", courseID: courseID)
            let lab = try await insertAssignment(
                testSetupID: try setup.requireID(), title: "Lab 0", courseID: courseID)

            let slides = APICourseContentItem(
                courseID: courseID, sortOrder: 1, title: "Lab 0 slides", kind: .slides,
                links: [ContentLink(label: "Slides", url: "https://example.com/lab0.pdf")])
            try await slides.save(on: app.db)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)
            let reading = APICourseContentItem(
                courseID: courseID, sortOrder: 2, title: "Reading", kind: .link,
                links: [ContentLink(label: "Link", url: "https://example.com/reading")])
            try await reading.save(on: app.db)

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "\(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_SHOW_ON").filter(\.$isArchived == false).first())
            let importedID = try imported.requireID()
            let importedLab = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == importedID).first())
            let importedItems = try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == importedID).all()
            let importedSlides = try #require(importedItems.first { $0.title == "Lab 0 slides" })
            #expect(importedSlides.assignmentID == importedLab.id)
            #expect(importedSlides.assignmentID != lab.id)
            let importedReading = try #require(importedItems.first { $0.title == "Reading" })
            #expect(importedReading.assignmentID == nil)
        }
    }

    @Test func roundTripPreservesContentAttachments() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "RT_ATTACH")
            let courseID = try course.requireID()

            let item = APICourseContentItem(
                courseID: courseID, sortOrder: 1, title: "Slides", kind: .slides, isPublished: true)
            try await item.save(on: app.db)
            let itemID = try item.requireID()
            let bytes = Data("SLIDE-DECK-BYTES".utf8)
            let attachment = try await ContentAttachmentStore.store(
                bytes: bytes, originalName: "week1.pdf", label: "Week 1", sortOrder: 1,
                itemID: itemID, on: makeTestRequest(on: app))
            item.attachments = [attachment]
            try await item.save(on: app.db)

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })

            // Manifest carries the attachment metadata + the bytes are in the zip.
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-attach-ext-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            let zipVerifyPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-attach-\(UUID().uuidString).zip").path
            defer { try? FileManager.default.removeItem(atPath: zipVerifyPath) }
            try exportedZip.write(to: URL(fileURLWithPath: zipVerifyPath))
            try await extractZipArchive(zipPath: zipVerifyPath, into: extractDir)
            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)
            let bundledItem = try #require(manifest.contentItems?.first { $0.title == "Slides" })
            let bundledAtt = try #require(bundledItem.attachments?.first)
            #expect(bundledAtt.originalName == "week1.pdf")
            #expect(bundledAtt.label == "Week 1")
            let contentFile = extractDir.appendingPathComponent(bundledAtt.bundleFilename)
            #expect(try Data(contentsOf: contentFile) == bytes)

            // Archive + import into a fresh course; the file bytes survive under
            // a regenerated attachment id.
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "\(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_ATTACH").filter(\.$isArchived == false).first())
            let importedItem = try #require(
                try await APICourseContentItem.query(on: app.db)
                    .filter(\.$courseID == imported.requireID()).first())
            let importedAtt = try #require(importedItem.attachments.first)
            #expect(importedAtt.originalName == "week1.pdf")
            #expect(importedAtt.id != attachment.id, "attachment id is regenerated on import")
            let importedPath = ContentAttachmentStore.path(
                app, itemID: try importedItem.requireID(), attachmentID: importedAtt.id)
            #expect(try Data(contentsOf: URL(fileURLWithPath: importedPath)) == bytes)
        }
    }

    // MARK: - Lecture notebooks: export → import, and a bundle with no lecture setup

    /// A lecture notebook item points at its backing setup. Import gives the
    /// setup a new ID, so the imported item must point at the imported setup,
    /// not at the source course's setup (docs/lecture-notebooks.md).
    @Test func roundTripPointsALectureNotebookAtTheImportedSetup() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "RT_LECTURE")
            let courseID = try course.requireID()
            let draft = try ContentItemDraft(
                title: "Lecture 2: Vectors", kind: ContentItemKind.notebook.rawValue, links: [],
                description: nil, updatedLabel: nil, isPublished: true)
            let source = try await LectureNotebookService.create(
                draft, language: .python, notebookData: nil, in: (courseID, nil),
                setupsDirectory: app.testSetupsDirectory, on: app.db)
            let sourceSetupID = try #require(source.lectureTestSetupID)

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "\(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_LECTURE").filter(\.$isArchived == false).first())
            let importedID = try imported.requireID()
            let importedSetup = try #require(
                try await APITestSetup.query(on: app.db).filter(\.$courseID == importedID).first())
            let importedSetupID = try importedSetup.requireID()
            let importedItem = try #require(
                try await APICourseContentItem.query(on: app.db).filter(\.$courseID == importedID).first())
            #expect(importedItem.title == "Lecture 2: Vectors")
            #expect(importedItem.lectureTestSetupID == importedSetupID)
            #expect(importedItem.lectureTestSetupID != sourceSetupID)
            #expect(importedItem.isLectureNotebook)
        }
    }

    /// A bundle can name a lecture setup that it does not carry (for example,
    /// a bundle edited by hand). Import keeps the item as an ordinary item and
    /// does not point it at a setup.
    @Test func importKeepsALectureItemWithNoBundledSetupAsAnOrdinaryItem() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let zipData = try await makeMinimalBundleZip(
                courseCode: "RT_LECTURE_ORPHAN",
                contentItems: [
                    BundledContentItem(
                        sectionBundleID: nil, title: "Lecture 9", kind: ContentItemKind.notebook.rawValue,
                        description: nil, links: [], updatedLabel: nil, isPublished: true, sortOrder: 1,
                        lectureSetupBundleID: "setup_absent")
                ])
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_LECTURE_ORPHAN").filter(\.$isArchived == false).first())
            let item = try #require(
                try await APICourseContentItem.query(on: app.db)
                    .filter(\.$courseID == (try imported.requireID())).first())
            #expect(item.title == "Lecture 9")
            #expect(item.lectureTestSetupID == nil)
            #expect(!item.isLectureNotebook)
        }
    }
}
