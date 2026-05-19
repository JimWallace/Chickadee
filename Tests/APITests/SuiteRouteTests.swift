// Tests/APITests/SuiteRouteTests.swift
//
// HTTP tests for the unified suite editor introduced in v0.4.79:
//   GET  /instructor/:assignmentID/suite  → author-facing items list
//   PUT  /instructor/:assignmentID/suite  → replace the list atomically
//
// The PUT endpoint is the single mutation surface for the assignment-edit
// table: reorder, adopt-as-dependency, tier/points/displayName edits, and
// family CRUD all flow through it.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class SuiteRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-suite-rt")
    }

    // MARK: - Fixtures

    private func makeAssignment(
        withScripts scripts: [(String, String)] = [("publictest_a.py", "passed('ok')\n")]
    ) async throws -> String {
        let courseID = UUID()
        let course = APICourse(id: courseID, code: "SRT", name: "Suite Route Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "srt_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: [(".placeholder", "x")] + scripts)

        var entries: [ConfiguredSuiteEntry] = []
        for (i, (name, _)) in scripts.enumerated() {
            entries.append(
                ConfiguredSuiteEntry(
                    script: name, tier: "public", order: i + 1,
                    dependsOn: [], points: 1, displayName: nil
                ))
        }
        let manifest = try makeWorkerManifestJSON(testSuites: entries, includeMakefile: false)
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "SRT test",
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID
        )
        try await assignment.save(on: app.db)
        return assignment.publicID
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srt-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
    }

    private func csrfPair(for id: String, cookie: String) async throws -> (String, String) {
        return try await csrfFields(for: "/instructor/\(id)/edit", cookie: cookie, on: app)
    }

    // MARK: - GET /suite

    @Test func get_returnsEmptyForNoManifest() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            try await app.asyncTest(
                .GET, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("\"items\":[]"))
                })

        }
    }

    @Test func get_returnsScriptRowsInManifestOrder() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [
                ("publictest_first.py", "passed('1')\n"),
                ("publictest_second.py", "passed('2')\n"),
            ])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            try await app.asyncTest(
                .GET, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let s = res.body.string
                    let firstIdx = try #require(s.range(of: "publictest_first.py")?.lowerBound)
                    let secondIdx = try #require(s.range(of: "publictest_second.py")?.lowerBound)
                    #expect(firstIdx < secondIdx, "first should precede second in the payload")
                })

        }
    }

    // MARK: - PUT /suite

    @Test func put_reorderScriptsRoundTripsAcrossReload() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [
                ("publictest_a.py", "passed('a')\n"),
                ("publictest_b.py", "passed('b')\n"),
            ])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)

            let body = #"""
                {"items":[
                    {"kind":"script","script":{"script":"publictest_b.py","tier":"public","points":1,"displayName":null,"dependsOn":[]}},
                    {"kind":"script","script":{"script":"publictest_a.py","tier":"public","points":1,"displayName":null,"dependsOn":[]}}
                ]}
                """#

            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            try await app.asyncTest(
                .GET, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    let s = res.body.string
                    let aIdx = try #require(s.range(of: "publictest_a.py")?.lowerBound)
                    let bIdx = try #require(s.range(of: "publictest_b.py")?.lowerBound)
                    #expect(bIdx < aIdx, "b should now precede a")
                })

        }
    }

    @Test func put_adoptScriptOnFamilyCollapsesBackIntoFamilyToken() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [
                ("publictest_followup.py", "passed('ok')\n")
            ])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)

            // Add a family + a raw script that depends on it.
            let body = #"""
                {"items":[
                    {"kind":"family","family":{
                        "id":"bmi","name":"BMI","kind":"boundary_equality",
                        "functionName":"bmi_category","paramNames":["bmi"],
                        "defaults":{"tier":"public","points":1},
                        "cases":[
                            {"key":"01","label":"low","args":[18.49],"expected":"underweight","enabled":true},
                            {"key":"02","label":"mid","args":[22.0],"expected":"normal","enabled":true}
                        ],
                        "dependsOn":[]
                    },"dependsOn":[]},
                    {"kind":"script","script":{"script":"publictest_followup.py","tier":"public","points":1,"displayName":null,"dependsOn":["family:bmi"]}}
                ]}
                """#

            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            // Persisted manifest must have expanded filenames, not family:bmi.
            let assignment = try #require(try await APIAssignment.query(on: app.db).filter(\.$publicID == id).first())
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            let followup = try #require(props.testSuites.first { $0.script == "publictest_followup.py" })
            #expect(
                Set(followup.dependsOn)
                    == Set([
                        "publictest_bmi_01.py", "publictest_bmi_02.py",
                    ]))

            // GET /suite should collapse those expanded names back into "family:bmi".
            try await app.asyncTest(
                .GET, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(
                        res.body.string.contains("\"dependsOn\":[\"family:bmi\"]"),
                        "Expected dependsOn to collapse into family:bmi in: \(res.body.string)")
                })

        }
    }

    @Test func put_removingFamilyDropsDanglingFamilyRefs() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [
                ("publictest_followup.py", "passed('ok')\n")
            ])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)

            // Add + then remove a family, with a script that had depended on it.
            let withFamily = #"""
                {"items":[
                    {"kind":"family","family":{
                        "id":"bmi","name":"BMI","kind":"boundary_equality",
                        "functionName":"bmi_category","paramNames":["bmi"],
                        "defaults":{"tier":"public","points":1},
                        "cases":[{"key":"01","label":"low","args":[18.49],"expected":"underweight","enabled":true}]
                    }},
                    {"kind":"script","script":{"script":"publictest_followup.py","tier":"public","points":1,"displayName":null,"dependsOn":["family:bmi"]}}
                ]}
                """#
            let withoutFamily = #"""
                {"items":[
                    {"kind":"script","script":{"script":"publictest_followup.py","tier":"public","points":1,"displayName":null,"dependsOn":[]}}
                ]}
                """#

            for body in [withFamily, withoutFamily] {
                try await app.asyncTest(
                    .PUT, "/instructor/\(id)/suite",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: sessionCookie)
                        req.headers.add(name: "x-csrf-token", value: csrf)
                        req.headers.contentType = .json
                        req.body = ByteBuffer(string: body)
                    },
                    afterResponse: { res in
                        #expect(res.status == .ok, "\(res.body.string)")
                    })
            }

            let assignment = try #require(try await APIAssignment.query(on: app.db).filter(\.$publicID == id).first())
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let entries = Set(listZipEntries(zipPath: setup.zipPath))
            #expect(
                entries.contains("publictest_bmi_01.py") == false,
                "Generated script must be gone from the zip after family removal")
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.patternFamilies.isEmpty)
            let followup = try #require(props.testSuites.first { $0.script == "publictest_followup.py" })
            #expect(followup.dependsOn.isEmpty)

        }
    }

    // v0.4.80: `family.defaults.points` should propagate to every
    // generated TestSuiteEntry so the suite-row Pts input works as
    // "grade weight per generated case."
    @Test func put_familyDefaultsPointsAppliedToGeneratedEntries() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)
            let body = #"""
                {"items":[
                    {"kind":"family","family":{
                        "id":"bmi","name":"BMI","kind":"boundary_equality",
                        "functionName":"bmi_category","paramNames":["bmi"],
                        "defaults":{"tier":"public","points":3},
                        "cases":[
                            {"key":"01","label":"a","args":[18.49],"expected":"underweight","enabled":true},
                            {"key":"02","label":"b","args":[22.0],"expected":"normal","enabled":true}
                        ]
                    }}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            let assignment = try #require(try await APIAssignment.query(on: app.db).filter(\.$publicID == id).first())
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            let generated = props.testSuites.filter { $0.generatedBy != nil }
            #expect(generated.count == 2)
            for entry in generated {
                #expect(entry.points == 3)
            }

        }
    }

    // v0.4.80: .approximateEquality kind round-trips cleanly through PUT
    // and generates Python that uses `abs(result - expected) > tolerance`.
    @Test func put_approximateEqualityKindRoundTrip() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)
            let body = #"""
                {"items":[
                    {"kind":"family","family":{
                        "id":"bmi","name":"BMI","kind":"approximate_equality",
                        "functionName":"bmi","paramNames":["mass_kg","height_m"],
                        "defaults":{"tier":"public","points":1,"tolerance":0.01},
                        "cases":[
                            {"key":"01","label":"adult","args":[70.0,1.75],"expected":22.857,"enabled":true}
                        ]
                    }}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            let assignment = try #require(try await APIAssignment.query(on: app.db).filter(\.$publicID == id).first())
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            // The generated .py must contain the approx-kind comparison.
            let source = try #require(
                readScriptFromZip(
                    zipPath: setup.zipPath,
                    filename: "publictest_bmi_01.py"
                ))
            #expect(source.contains("tolerance = 0.01"), "\(source)")
            #expect(source.contains("delta = abs(result - expected)"), "\(source)")
            #expect(source.contains("if delta > tolerance:"), "\(source)")

        }
    }

    // v0.4.80: tolerance < 0 is rejected at the /suite boundary.
    @Test func put_rejectsNegativeTolerance() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)
            let body = #"""
                {"items":[
                    {"kind":"family","family":{
                        "id":"bad","name":"bad","kind":"approximate_equality",
                        "functionName":"f","paramNames":["x"],
                        "defaults":{"tier":"public","points":1,"tolerance":-0.5},
                        "cases":[
                            {"key":"01","label":"a","args":[1],"expected":1,"enabled":true}
                        ]
                    }}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .unprocessableEntity)
                    #expect(res.body.string.contains("tolerance"))
                })

        }
    }

    // Regression for v0.4.157→0.4.158: a notebook-check row dragged
    // (or otherwise re-PUT) via the suite editor used to fail with the
    // "would generate '…', but a hand-written file with that name
    // already exists" collision, because the frontend round-tripped the
    // check as kind:"script" with the generated filename.  With the fix,
    // the GET returns kind:"check" and the PUT accepts it back without
    // confusing the check's own generated entry for a hand-written
    // script.
    @Test func put_notebookCheckRowRoundTripsAcrossDrag() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment(withScripts: [])
            let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
            let (csrf, sessionCookie) = try await csrfPair(for: id, cookie: cookie)

            // Step 1: install a notebook check via PUT /checks.
            let checksBody = #"""
                [{"id":"var_exists_x","name":"x exists","kind":"variable_exists",
                  "tier":"public","points":1,"variable":"x"}]
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(id)/checks",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: checksBody)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            // Step 2: GET /suite should now include the check as kind:"check".
            var initialCheckPayload = ""
            try await app.asyncTest(
                .GET, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    initialCheckPayload = res.body.string
                    #expect(
                        initialCheckPayload.contains("\"kind\":\"check\""),
                        "Expected GET /suite to emit a check row; got: \(initialCheckPayload)")
                })

            // Step 3: PUT /suite with the same check row, simulating a drag
            // (carries the check spec verbatim, no sectionID).  Without the
            // fix this fails with the bogus collision error.
            let suiteBody = #"""
                {"items":[
                    {"kind":"check","check":{"id":"var_exists_x","name":"x exists","kind":"variable_exists",
                      "tier":"public","points":1,"dependsOn":[],"variable":"x"}}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: suiteBody)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            // Step 4: the manifest still has exactly one notebook check
            // entry pointing at the same id; no spurious hand-written script
            // got created for the generated filename.
            let assignment = try #require(try await APIAssignment.query(on: app.db).filter(\.$publicID == id).first())
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.notebookChecks.map(\.id) == ["var_exists_x"])
            let checkEntries = props.testSuites.filter { $0.generatedByCheck == "var_exists_x" }
            #expect(checkEntries.count == 1)
            let handWrittenSameName = props.testSuites.filter {
                $0.generatedByCheck == nil && $0.script == checkEntries.first?.script
            }
            #expect(
                handWrittenSameName.isEmpty,
                "No hand-written entry should have been created for the check's generated filename.")

        }
    }

    @Test func put_studentCannotEdit() async throws {
        try await withApp(app) { _ in
            let id = try await makeAssignment()
            let studentCookie = try await loginUser(username: "stu", password: "pw", role: "student", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: studentCookie, on: app)
            try await app.asyncTest(
                .PUT, "/instructor/\(id)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"items":[]}"#)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden || res.status == .seeOther || res.status == .notFound,
                        "Expected forbidden/redirect for student PUT, got \(res.status)")
                })

        }
    }
}
