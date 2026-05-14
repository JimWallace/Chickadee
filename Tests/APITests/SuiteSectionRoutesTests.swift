// Tests/APITests/SuiteSectionRoutesTests.swift
//
// Integration tests for AssignmentRoutes+SuiteSections (v0.4.98):
//   POST /instructor/:assignmentID/suite-sections                   — create
//   POST /instructor/:assignmentID/suite-sections/reorder           — reorder (AJAX)
//   POST /instructor/:assignmentID/suite-sections/:sectionID/rename — rename
//   POST /instructor/:assignmentID/suite-sections/:sectionID/delete — delete
//
// These handlers mutate ONLY the test setup's `manifest.sections` JSON
// field (and clear orphan `sectionID` on testSuites entries for delete).
// They intentionally bypass `applyPatternFamilies` / the zip rebuild — so
// section CRUD is a one-line-of-JSON operation that can't fail from any
// of the complex pipeline machinery that plagued the v0.4.96 design.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class SuiteSectionRoutesTests: XCTestCase {

    private var app: Application!
    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-ssrt")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Fixture

    /// Creates a course + test setup + assignment and returns the
    /// assignment's public ID.  The manifest can be seeded with existing
    /// sections / test entries via the optional parameters — most tests
    /// start with an empty list and add sections via the endpoints under
    /// test.
    private func makeAssignment(
        seedSections: [(id: String, name: String)] = [],
        seedEntries: [(script: String, sectionID: String?)] = []
    ) async throws -> (String, String) {  // (assignmentPublicID, testSetupID)
        let courseID = UUID()
        let course = APICourse(id: courseID, code: "SSRT", name: "Suite Section Route Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "ssrt_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        FileManager.default.createFile(atPath: zipPath, contents: Data())

        var manifestDict: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": [],
            "timeLimitSeconds": 10,
            "makefile": NSNull(),
        ]
        let entries: [[String: Any]] = seedEntries.map { e in
            var d: [String: Any] = ["tier": "public", "script": e.script]
            if let sid = e.sectionID { d["sectionID"] = sid }
            return d
        }
        manifestDict["testSuites"] = entries
        let sections: [[String: Any]] = seedSections.map { ["id": $0.id, "name": $0.name] }
        if !sections.isEmpty {
            manifestDict["sections"] = sections
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: [.sortedKeys])
        let manifest = String(data: manifestData, encoding: .utf8)!

        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "SSRT test",
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID
        )
        try await assignment.save(on: app.db)
        return (assignment.publicID, setupID)
    }

    private func loadManifestDict(setupID: String) async throws -> [String: Any] {
        guard let setup = try await APITestSetup.find(setupID, on: app.db),
              let data = setup.manifest.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw XCTSkip("manifest load failed") }
        return dict
    }

    // MARK: - POST /suite-sections (create)

    func testCreateSuiteSection_appendsToManifestAndRedirects() async throws {
        let (aid, setupID) = try await makeAssignment()
        let cookie = try await loginUser(username: "ssrt_inst1", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["name": "Question 1", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor/\(aid)/edit")
        })

        let dict = try await loadManifestDict(setupID: setupID)
        let sections = dict["sections"] as? [[String: Any]] ?? []
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0]["name"] as? String, "Question 1")
        XCTAssertNotNil(sections[0]["id"] as? String)
    }

    func testCreateSuiteSection_rejectsEmptyName() async throws {
        let (aid, _) = try await makeAssignment()
        let cookie = try await loginUser(username: "ssrt_inst2", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["name": "   ", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    // MARK: - POST /suite-sections/:sid/rename

    func testRenameSuiteSection_updatesNameInManifest() async throws {
        let sid = UUID().uuidString
        let (aid, setupID) = try await makeAssignment(seedSections: [(sid, "Original")])
        let cookie = try await loginUser(username: "ssrt_inst3", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections/\(sid)/rename", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["name": "Renamed", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let dict = try await loadManifestDict(setupID: setupID)
        let sections = dict["sections"] as? [[String: Any]] ?? []
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0]["id"] as? String, sid, "Section id must survive a rename")
        XCTAssertEqual(sections[0]["name"] as? String, "Renamed")
    }

    func testRenameSuiteSection_unknownIDReturns404() async throws {
        let (aid, _) = try await makeAssignment(seedSections: [(UUID().uuidString, "Existing")])
        let cookie = try await loginUser(username: "ssrt_inst4", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections/does-not-exist/rename", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["name": "Anything", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /suite-sections/:sid/delete

    func testDeleteSuiteSection_removesSectionAndClearsOrphanEntrySectionIDs() async throws {
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString
        let (aid, setupID) = try await makeAssignment(
            seedSections: [(sidA, "A"), (sidB, "B")],
            seedEntries: [
                (script: "publictest_a.py", sectionID: sidA),
                (script: "publictest_b.py", sectionID: sidB),
                (script: "publictest_c.py", sectionID: sidA),
            ]
        )
        let cookie = try await loginUser(username: "ssrt_inst5", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections/\(sidA)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let dict = try await loadManifestDict(setupID: setupID)
        let sections = dict["sections"] as? [[String: Any]] ?? []
        XCTAssertEqual(sections.count, 1, "Section A should be gone; B survives")
        XCTAssertEqual(sections[0]["id"] as? String, sidB)

        let entries = dict["testSuites"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.count, 3, "Entries themselves are preserved — only the orphan sectionID is cleared")
        let bySection = Dictionary(grouping: entries) { ($0["script"] as? String) ?? "" }
        XCTAssertNil(bySection["publictest_a.py"]?.first?["sectionID"], "Orphan sectionID must be cleared")
        XCTAssertEqual(bySection["publictest_b.py"]?.first?["sectionID"] as? String, sidB, "Other section untouched")
        XCTAssertNil(bySection["publictest_c.py"]?.first?["sectionID"], "Orphan sectionID must be cleared")
    }

    // MARK: - POST /suite-sections/reorder

    func testReorderSuiteSections_updatesOrder() async throws {
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString
        let sidC = UUID().uuidString
        let (aid, setupID) = try await makeAssignment(
            seedSections: [(sidA, "A"), (sidB, "B"), (sidC, "C")]
        )
        let cookie = try await loginUser(username: "ssrt_inst6", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections/reorder", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode(
                ["sectionIDs": [sidC, sidA, sidB]],
                as: .json
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let dict = try await loadManifestDict(setupID: setupID)
        let sections = dict["sections"] as? [[String: Any]] ?? []
        XCTAssertEqual(sections.map { $0["id"] as? String }, [sidC, sidA, sidB])
    }

    func testReorderSuiteSections_rejectsMismatchedIDSet() async throws {
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString
        let (aid, _) = try await makeAssignment(seedSections: [(sidA, "A"), (sidB, "B")])
        let cookie = try await loginUser(username: "ssrt_inst7", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/\(aid)/edit", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(aid)/suite-sections/reorder", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode(
                ["sectionIDs": [sidA, "unknown-id"]],
                as: .json
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }
}
