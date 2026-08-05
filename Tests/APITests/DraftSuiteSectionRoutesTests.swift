// Tests/APITests/DraftSuiteSectionRoutesTests.swift
//
// Integration tests for AssignmentRoutes+DraftSections (v0.4.132 / #435):
//   POST /instructor/new/draft/suite-sections                       — create
//   POST /instructor/new/draft/suite-sections/reorder               — reorder (AJAX)
//   POST /instructor/new/draft/suite-sections/:sectionID/rename     — rename
//   POST /instructor/new/draft/suite-sections/:sectionID/delete     — delete
//   POST /instructor/new/draft/suite-sections/:sectionID/variables  — variables
//
// Mirrors `SuiteSectionRoutesTests` (the assignment-scoped variant) but
// the fixture creates an `APITestSetup` row directly without an
// `APIAssignment` parent — that row IS the draft.  Each request
// includes `?draftID=<setupID>`.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class DraftSuiteSectionRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dssrt")
    }

    // MARK: - Fixture

    /// Creates a course + draft test setup (no parent assignment) and
    /// returns the setupID for use as `?draftID=`.
    private func makeDraft(
        seedSections: [(id: String, name: String)] = [],
        seedEntries: [(script: String, sectionID: String?)] = []
    ) async throws -> String {
        let courseID = UUID()
        let course = APICourse(
            id: courseID, code: "DSSRT", name: "Draft Suite Section Route Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "dssrt_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        _ = FileManager.default.createFile(atPath: zipPath, contents: Data())

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
        let manifest = try #require(String(data: manifestData, encoding: .utf8))

        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setupID
    }

    private func loadManifestDict(setupID: String) async throws -> [String: Any] {
        guard let setup = try await APITestSetup.find(setupID, on: app.db),
            let data = setup.manifest.data(using: .utf8),
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw IssueRecorded("manifest load failed") }
        return dict
    }

    // MARK: - POST /instructor/new/draft/suite-sections (create)

    @Test func createDraftSuiteSection_appendsToManifestAndRedirects() async throws {
        try await withApp(app) { _ in
            let draftID = try await makeDraft()
            let cookie = try await loginUser(username: "dssrt_inst1", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst1", on: app)
            // CSRF token cooks against any GET — the create page itself works fine here.
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["name": "Question 1", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/new?draftID=\(draftID)")
                })

            let dict = try await loadManifestDict(setupID: draftID)
            let sections = dict["sections"] as? [[String: Any]] ?? []
            #expect(sections.count == 1)
            #expect(sections[0]["name"] as? String == "Question 1")
            #expect(sections[0]["id"] is String)

        }
    }

    @Test func createDraftSuiteSection_rejectsEmptyName() async throws {
        try await withApp(app) { _ in
            let draftID = try await makeDraft()
            let cookie = try await loginUser(username: "dssrt_inst2", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst2", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["name": "   ", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    @Test func createDraftSuiteSection_missingDraftIDReturns400() async throws {
        try await withApp(app) { _ in
            _ = try await makeDraft()
            let cookie = try await loginUser(username: "dssrt_inst3", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst3", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["name": "Whatever", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sid/rename

    @Test func renameDraftSuiteSection_updatesNameInManifest() async throws {
        try await withApp(app) { _ in
            let sid = UUID().uuidString
            let draftID = try await makeDraft(seedSections: [(sid, "Original")])
            let cookie = try await loginUser(username: "dssrt_inst4", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst4", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/\(sid)/rename?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["name": "Renamed", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let dict = try await loadManifestDict(setupID: draftID)
            let sections = dict["sections"] as? [[String: Any]] ?? []
            #expect(sections.count == 1)
            #expect(sections[0]["id"] as? String == sid, "Section id must survive a rename")
            #expect(sections[0]["name"] as? String == "Renamed")

        }
    }

    @Test func renameDraftSuiteSection_unknownIDReturns404() async throws {
        try await withApp(app) { _ in
            let draftID = try await makeDraft(seedSections: [(UUID().uuidString, "Existing")])
            let cookie = try await loginUser(username: "dssrt_inst5", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst5", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/does-not-exist/rename?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["name": "Anything", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sid/delete

    @Test func deleteDraftSuiteSection_removesSectionAndClearsOrphanEntrySectionIDs() async throws {
        try await withApp(app) { _ in
            let sidA = UUID().uuidString
            let sidB = UUID().uuidString
            let draftID = try await makeDraft(
                seedSections: [(sidA, "A"), (sidB, "B")],
                seedEntries: [
                    (script: "publictest_a.py", sectionID: sidA),
                    (script: "publictest_b.py", sectionID: sidB),
                    (script: "publictest_c.py", sectionID: sidA),
                ]
            )
            let cookie = try await loginUser(username: "dssrt_inst6", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst6", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/\(sidA)/delete?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let dict = try await loadManifestDict(setupID: draftID)
            let sections = dict["sections"] as? [[String: Any]] ?? []
            #expect(sections.count == 1, "Section A should be gone; B survives")
            #expect(sections[0]["id"] as? String == sidB)

            let entries = dict["testSuites"] as? [[String: Any]] ?? []
            #expect(entries.count == 3, "Entries themselves are preserved — only the orphan sectionID is cleared")
            let bySection = Dictionary(grouping: entries) { ($0["script"] as? String) ?? "" }
            #expect(bySection["publictest_a.py"]?.first?["sectionID"] == nil, "Orphan sectionID must be cleared")
            #expect(bySection["publictest_b.py"]?.first?["sectionID"] as? String == sidB, "Other section untouched")
            #expect(bySection["publictest_c.py"]?.first?["sectionID"] == nil, "Orphan sectionID must be cleared")

        }
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sid/variables

    @Test func updateDraftSuiteSectionVariables_persistsAndValidates() async throws {
        try await withApp(app) { _ in
            let sid = UUID().uuidString
            let draftID = try await makeDraft(seedSections: [(sid, "Q1")])
            let cookie = try await loginUser(username: "dssrt_inst7", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst7", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            // Persist a valid pair (use the real `FamilyVariable` shape — same
            // Codable type the handler decodes — to dodge the heterogeneous-
            // dict type-inference cliff).
            struct VariablesBody: Content {
                var variables: [FamilyVariable]
            }
            let validBody = VariablesBody(variables: [
                FamilyVariable(name: "vals", value: .array([.int(1), .int(2), .int(3)])),
                FamilyVariable(name: "scale", value: .double(1.5)),
            ])
            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/\(sid)/variables?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(validBody, as: .json)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let dict = try await loadManifestDict(setupID: draftID)
            let sections = dict["sections"] as? [[String: Any]] ?? []
            #expect(sections.count == 1)
            let vars = sections[0]["variables"] as? [[String: Any]]
            #expect(vars?.count == 2)
            #expect(vars?.first?["name"] as? String == "vals")

            // Reject duplicate names.
            let dupeBody = VariablesBody(variables: [
                FamilyVariable(name: "x", value: .int(1)),
                FamilyVariable(name: "x", value: .int(2)),
            ])
            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/\(sid)/variables?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(dupeBody, as: .json)
                },
                afterResponse: { res in
                    #expect(res.status == .unprocessableEntity)
                })

            // Reject non-identifier names.
            let badIdentBody = VariablesBody(variables: [
                FamilyVariable(name: "1bad", value: .int(1))
            ])
            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/\(sid)/variables?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(badIdentBody, as: .json)
                },
                afterResponse: { res in
                    #expect(res.status == .unprocessableEntity)
                })

        }
    }

    /// The draft endpoint has always accepted per-student `=` expressions —
    /// it decodes an optional `expressions` list alongside `variables` — but
    /// nothing exercised that path, and until v0.5.x the create page's inline
    /// editor never sent the key. A payload without it is coalesced to `[]`,
    /// so an expression authored on that page was silently downgraded to a
    /// literal string. This pins the server half of the contract the page's
    /// shared editor module now relies on.
    @Test func updateDraftSuiteSectionVariables_roundTripsPerStudentExpressions() async throws {
        try await withApp(app) { _ in
            let sid = UUID().uuidString
            let draftID = try await makeDraft(seedSections: [(sid, "Q1")])
            let cookie = try await loginUser(username: "dssrt_inst8", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst8", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            struct MixedBody: Content {
                var variables: [FamilyVariable]
                var expressions: [PersonalizationExpression]
            }
            let body = MixedBody(
                variables: [FamilyVariable(name: "max_bmi", value: .int(30))],
                expressions: [PersonalizationExpression(name: "shift", expression: "seed % 26")]
            )
            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/\(sid)/variables?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(body, as: .json)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            // The expression survives as an expression, not as a literal whose
            // value happens to be the text "= seed % 26".
            let dict = try await loadManifestDict(setupID: draftID)
            let sections = try #require(dict["sections"] as? [[String: Any]])
            #expect(sections.count == 1)

            let vars = sections[0]["variables"] as? [[String: Any]] ?? []
            #expect(vars.count == 1)
            #expect(vars.first?["name"] as? String == "max_bmi")
            #expect(
                vars.contains { ($0["name"] as? String) == "shift" } == false,
                "The expression must not land in `variables`")

            let exprs = try #require(sections[0]["expressions"] as? [[String: Any]])
            #expect(exprs.count == 1)
            #expect(exprs.first?["name"] as? String == "shift")
            #expect(exprs.first?["expression"] as? String == "seed % 26")

            // And it renders back into the editor with the `=` prefix the
            // shared value parser classifies on load — the same helper the
            // create and edit templates both loop over.
            let setup = try await APITestSetup.find(draftID, on: app.db)
            let manifest = try #require(setup?.manifest)
            let rows = suiteSectionShellRows(fromManifest: manifest)
            let shiftRow = try #require(
                rows.first?.variables.first { $0.name == "shift" },
                "The expression should render as a section-input row")
            #expect(shiftRow.valueJSON == "= seed % 26")
        }
    }

    /// The draft suite endpoint is registered for GET and PUT only. That is
    /// what made suite-table.js's old reorder-URL derivation a live bug: it
    /// rewrote a trailing path segment of `putSuite()`, which on this page
    /// ends in a query string, so the rewrite was a no-op and the section
    /// reorder POSTed here instead of to `/suite-sections/reorder`. The
    /// request was rejected and the instructor saw "Section reorder failed".
    ///
    /// Pinned so that adding a POST handler here — which would make the old
    /// derivation silently "work" while writing the wrong payload to the
    /// wrong handler — is a deliberate act with a red test attached.
    @Test func draftSuiteEndpointRejectsPOST() async throws {
        try await withApp(app) { _ in
            let sid = UUID().uuidString
            let draftID = try await makeDraft(seedSections: [(sid, "Q1")])
            let cookie = try await loginUser(username: "dssrt_inst9", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst9", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            struct ReorderBody: Content { var sectionIDs: [String] }

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(ReorderBody(sectionIDs: [sid]), as: .json)
                },
                afterResponse: { res in
                    #expect(
                        res.status.code >= 400 && res.status.code < 500,
                        "POST to the draft suite endpoint must be rejected, got \(res.status)")
                })

            // The real endpoint accepts it.
            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/reorder?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(ReorderBody(sectionIDs: [sid]), as: .json)
                },
                afterResponse: { res in
                    #expect(res.status.code < 400, "the reorder endpoint should accept the payload")
                })
        }
    }

    /// The suite-section shells are one partial (`_suite-sections.leaf`)
    /// shared with the assignment edit body. The two surfaces differ only in
    /// where the per-section forms post and whether they carry
    /// `data-ck-inplace`, so this asserts the create page's *URLs*, not merely
    /// that the block rendered — a presence check would survive the partial
    /// being handed the edit page's base.
    ///
    /// The edit/workbench side of the same partial is pinned by
    /// InstructorWorkbenchRoutesTests.everyNavigatingWriteFormIsMarkedForInPlaceSubmission,
    /// which compares the exact set of marked form actions.
    @Test func newAssignmentPageRendersSectionShellsWithDraftScopedURLs() async throws {
        try await withApp(app) { _ in
            let sid = "sec_partial_1"
            let draftID = try await makeDraft(seedSections: [(sid, "Question 1")])
            let cookie = try await loginUser(username: "dssrt_inst10", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst10", on: app)

            try await app.asyncTest(
                .GET, "/instructor/new?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string

                    // The section shell rendered at all.
                    #expect(html.contains("data-section-id=\"\(sid)\""))

                    // Parse the form open tags rather than searching the whole
                    // document: the partial's own comment names the marker
                    // attribute, so a textual check would match prose.
                    let tags = Self.formOpenTags(in: html)
                    let sectionActions = tags.compactMap { Self.attribute("action", in: $0) }
                        .filter { $0.contains("/suite-sections/") }

                    for op in ["rename", "variables"] {
                        let expected = "/instructor/new/draft/suite-sections/\(sid)/\(op)?draftID=\(draftID)"
                        #expect(
                            sectionActions.contains(expected),
                            "the \(op) action should be draft-scoped; expected \(expected), got \(sectionActions)")
                    }

                    // Delete is a button's data-action, not a form action.
                    #expect(
                        html.contains(
                            "data-action=\"/instructor/new/draft/suite-sections/\(sid)/delete?draftID=\(draftID)\""),
                        "the delete action should be draft-scoped")

                    // No section form may carry the edit page's published shape.
                    #expect(
                        sectionActions.allSatisfy { $0.contains("draftID=") },
                        "a section form is missing its draftID query: \(sectionActions)")

                    // The create page is never a workbench pane, so its forms
                    // must not be marked for in-place submission.
                    #expect(
                        tags.allSatisfy { $0.contains("data-ck-inplace") == false },
                        "the create page should not mark forms for in-place submission")
                })
        }
    }

    /// Every `<form>` open tag in `html`. Parsing the tags rather than
    /// searching the document keeps template prose out of the assertions —
    /// the same reason InstructorWorkbenchRoutesTests parses them.
    private static func formOpenTags(in html: String) -> [String] {
        html.components(separatedBy: "<form ").dropFirst().compactMap { chunk in
            guard let end = chunk.firstIndex(of: ">") else { return nil }
            return String(chunk[chunk.startIndex..<end])
        }
    }

    /// The value of a double-quoted attribute in a parsed open tag.
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[start.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<quote])
    }

    // MARK: - POST /instructor/new/draft/suite-sections/reorder

    @Test func reorderDraftSuiteSections_updatesOrder() async throws {
        try await withApp(app) { _ in
            let sidA = UUID().uuidString
            let sidB = UUID().uuidString
            let sidC = UUID().uuidString
            let draftID = try await makeDraft(
                seedSections: [(sidA, "A"), (sidB, "B"), (sidC, "C")]
            )
            let cookie = try await loginUser(username: "dssrt_inst8", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst8", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/reorder?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(
                        ["sectionIDs": [sidC, sidA, sidB]],
                        as: .json
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            let dict = try await loadManifestDict(setupID: draftID)
            let sections = dict["sections"] as? [[String: Any]] ?? []
            #expect(sections.map { $0["id"] as? String } == [sidC, sidA, sidB])

        }
    }

    @Test func reorderDraftSuiteSections_rejectsMismatchedIDSet() async throws {
        try await withApp(app) { _ in
            let sidA = UUID().uuidString
            let sidB = UUID().uuidString
            let draftID = try await makeDraft(seedSections: [(sidA, "A"), (sidB, "B")])
            let cookie = try await loginUser(username: "dssrt_inst9", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("dssrt_inst9", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/new/draft/suite-sections/reorder?draftID=\(draftID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: .init("x-csrf-token"), value: csrf)
                    try req.content.encode(
                        ["sectionIDs": [sidA, "unknown-id"]],
                        as: .json
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }
}
