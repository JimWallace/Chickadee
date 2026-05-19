// Tests/APITests/AssignmentRoutesPublishTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct AssignmentRoutesPublishTests {

    @Test func publishCreatesDraftAssignment() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_pub1", on: app)

            try await app.asyncTest(
                .POST, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["testSetupID": "setup_pub1", "title": "Lab 1", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    // Redirects to /instructor/:id/validate
                    #expect(res.status == .seeOther)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(
                        location.contains("/instructor/") && location.contains("/validate"),
                        "Expected redirect to /instructor/:id/validate, got \(location)")
                })

            // Assignment should be in DB as draft (isOpen: false)
            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$testSetupID == "setup_pub1")
                .first()
            #expect(assignment != nil)
            #expect(assignment?.title == "Lab 1")
            #expect(assignment?.isOpen == false)

        }
    }

    @Test func publishUnknownSetupReturnsBadRequest() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["testSetupID": "does_not_exist", "title": "Oops", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    @Test func publishDuplicateSetupRedirects() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_dup", on: app)
            try await arInsertAssignment(testSetupID: "setup_dup", title: "Already Published", isOpen: false, on: app)

            try await app.asyncTest(
                .POST, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["testSetupID": "setup_dup", "title": "Duplicate", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    // Should redirect to /instructor without creating a second record
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let count = try await APIAssignment.query(on: app.db)
                .filter(\.$testSetupID == "setup_dup")
                .count()
            #expect(count == 1)

        }
    }

    @Test func saveNewAssignmentAllowsMissingTestSuites() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
            let boundary = "Boundary-New-NoSuites"
            let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartAssignmentBody(
                            boundary: boundary,
                            csrf: csrf,
                            assignmentName: "No Tests Yet",
                            assignmentNotebook: notebook,
                            solutionNotebook: notebook
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "No Tests Yet")
                .first()
            #expect(assignment != nil)
            #expect(assignment?.validationStatus == nil)
            #expect(assignment?.validationSubmissionID == nil)

            let setupID = try #require(assignment?.testSetupID)
            let setup = try await APITestSetup.find(setupID, on: app.db)
            #expect(setup != nil)
            let setupManifest = try #require(setup?.manifest.data(using: .utf8))
            let props = try JSONDecoder().decode(TestProperties.self, from: setupManifest)
            #expect(props.testSuites.isEmpty)

        }
    }

    @Test func saveNewAssignmentPreservesMultipleUploadedSuiteFiles() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateRunnerProfiles())
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()
            let now = Date()
            let runnerProfile = RunnerProfile()
            runnerProfile.runnerID = "runner-multi-suite"
            runnerProfile.displayName = "Runner Multi Suite"
            runnerProfile.platform = "linux"
            runnerProfile.architecture = "x86_64"
            runnerProfile.languageVersionsJSON = "[]"
            runnerProfile.capabilitiesJSON = "[]"
            runnerProfile.profileHash = nil
            runnerProfile.lastRegisteredAt = now
            runnerProfile.lastSeenAt = now
            runnerProfile.isActive = true
            try await runnerProfile.save(on: app.db)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
            let boundary = "Boundary-New-MultiSuites"
            let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
            let suiteConfig = """
                [
                  {"index":0,"tier":"public","order":1,"points":1},
                  {"index":1,"tier":"public","order":2,"points":1},
                  {"index":2,"tier":"support","order":3,"points":1}
                ]
                """

            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartAssignmentBody(
                            boundary: boundary,
                            csrf: csrf,
                            assignmentName: "Practice Lab",
                            assignmentNotebook: notebook,
                            solutionNotebook: notebook,
                            suiteFiles: [
                                ("test_q1.py", "text/plain", "print('q1')"),
                                ("test_q2.py", "text/plain", "print('q2')"),
                                ("test.properties.json", "application/json", #"{"gradingMode":"browser"}"#),
                            ],
                            suiteConfig: suiteConfig
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "Practice Lab")
                .first()
            let setupID = try #require(assignment?.testSetupID)
            let setup = try await APITestSetup.find(setupID, on: app.db)
            #expect(setup != nil)

            let props = try JSONDecoder().decode(
                TestProperties.self,
                from: try #require(setup?.manifest.data(using: .utf8))
            )
            #expect(props.testSuites.map(\.script) == ["test_q1.py", "test_q2.py"])

            let zipEntries = Set(listZipEntries(zipPath: try #require(setup?.zipPath)))
            #expect(zipEntries.contains("test_q1.py"))
            #expect(zipEntries.contains("test_q2.py"))
            #expect(zipEntries.contains("test.properties.json"))

        }
    }

    // As of v0.4.79, suite metadata (displayName/tier/points/dependsOn) is
    // mutated live via `PUT /instructor/:id/suite`, not via the Save &
    // Validate form POST.  The two tests below exercise that flow.
    @Test func putSuitePersistsDisplayNameForExistingSuiteFile() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let setupID = "setup_edit_display"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            try arMakeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
                """
            let setup = APITestSetup(
                id: setupID, manifest: manifest, zipPath: zipPath,
                notebookPath: app.testSetupsDirectory + "notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
            try await setup.save(on: app.db)
            let assignment = APIAssignment(
                publicID: "ABC123", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false,
                courseID: courseID)
            try await assignment.save(on: app.db)

            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/ABC123/edit", cookie: cookie, on: app)
            let body = #"""
                {"items":[
                    {"kind":"script","script":{"script":"test_q1.py","tier":"public","points":1,"displayName":"BMI check","dependsOn":[]}}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/ABC123/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")

                })

            let savedSetup = try await APITestSetup.find(setupID, on: app.db)
            let props = try JSONDecoder().decode(
                TestProperties.self,
                from: try #require(savedSetup?.manifest.data(using: .utf8))
            )
            #expect(props.testSuites.count == 1)
            #expect(props.testSuites[0].name == "BMI check")

        }
    }

    @Test func putSuiteDisplayNameVisibleOnSubsequentEditPageLoad() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let setupID = "setup_edit_display_reload"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            try arMakeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
                """
            let setup = APITestSetup(
                id: setupID, manifest: manifest, zipPath: zipPath,
                notebookPath: app.testSetupsDirectory + "notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
            try await setup.save(on: app.db)
            let assignment = APIAssignment(
                publicID: "GHI789", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false,
                courseID: courseID)
            try await assignment.save(on: app.db)

            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/GHI789/edit", cookie: cookie, on: app)
            let body = #"""
                {"items":[
                    {"kind":"script","script":{"script":"test_q1.py","tier":"public","points":1,"displayName":"BMI check","dependsOn":[]}}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/GHI789/suite",
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
                .GET, "/instructor/GHI789/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    // The seeded suite-state JSON should carry the updated name.
                    #expect(res.body.string.contains("\"displayName\":\"BMI check\""), "\(res.body.string)")

                })

        }
    }

    @Test func newAssignmentPageWiresSuiteTableJS() async throws {
        try await withAssignmentRoutesApp { app in
            // Updated v0.4.132 (#435 / parity PR 1): the create page no
            // longer bundles suite changes through `chickadee:before-
            // multipart-submit` + `syncConfig()` + the legacy `suite-list.js`
            // IIFE.  Suite mutations now persist live via `suite-table.js`
            // against draft-scoped endpoints (`PUT /draft/suite`,
            // `POST /draft/scripts`, etc.); the multipart submit only
            // carries notebook bytes + assignment metadata.
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            try await app.asyncTest(
                .GET, "/instructor/new",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Legacy IIFE markers must be gone.
                    #expect(
                        html.contains("syncConfig();") == false,
                        "Legacy syncConfig() must not appear after the v0.4.132 rewrite")
                    #expect(
                        html.contains("chickadeeAddSuiteUploadFiles") == false,
                        "Legacy upload-queue global must not appear after the v0.4.132 rewrite")
                })

        }
    }

    @Test func newAssignmentPageOmitsLegacyTestColumn() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            try await app.asyncTest(
                .GET, "/instructor/new",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("<th>Test?</th>") == false,
                        "Legacy `Test?` column header must not appear on the create page")
                    #expect(
                        body.contains("id=\"suite-config-table\"") == false,
                        "Legacy `suite-config-table` must not appear after the v0.4.132 rewrite")
                })

        }
    }

    @Test func updateNewAssignmentDraftCreatesBlankNotebookAndRendersDraftState() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
            let boundary = "Boundary-New-Draft-Create"

            var redirectLocation: String?
            try await app.asyncTest(
                .POST, "/instructor/new/draft",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", csrf),
                                ("assignmentName", "Blank Draft Lab"),
                                ("draftAction", "create-assignment-notebook"),
                            ]
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    redirectLocation = res.headers.first(name: .location)
                    #expect((redirectLocation ?? "").contains("/instructor/new?draftID="))
                })

            let setup = try await APITestSetup.query(on: app.db).first()
            #expect(setup != nil)
            #expect(FileManager.default.fileExists(atPath: try #require(setup?.notebookPath)))

            try await app.asyncTest(
                .GET, try #require(redirectLocation),
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Blank Draft Lab"))
                    #expect(html.contains("Assignment Notebook"))  // notebook table row
                    #expect(html.contains("Edit"))
                })

        }
    }

    @Test func saveNewAssignmentFinalizesDraftAndPersistsRequirements() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            let setupID = "setup_draft_finalize"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
            let manifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "worker")
            let notebookDir = app.testSetupsDirectory + "notebooks/\(setupID)/"
            try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
            let assignmentPath = notebookDir + "assignment.ipynb"
            try defaultNotebookData(title: "Draft Finalize").write(to: URL(fileURLWithPath: assignmentPath))
            let solutionPath = draftSolutionNotebookPath(
                testSetupsDirectory: app.testSetupsDirectory + "", setupID: setupID)
            try defaultNotebookData(title: "Draft Finalize Solution").write(to: URL(fileURLWithPath: solutionPath))

            let setup = APITestSetup(
                id: setupID,
                manifest: manifest,
                zipPath: zipPath,
                notebookPath: assignmentPath,
                courseID: courseID
            )
            try await setup.save(on: app.db)

            let boundary = "Boundary-New-Finalize-Draft"
            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", csrf),
                                ("draftID", setupID),
                                ("assignmentName", "Draft-backed Lab"),
                                ("requiredLanguagesCSV", "python"),
                                ("requiredCapabilitiesCSV", "numpy, pandas"),
                            ]
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "Draft-backed Lab")
                .first()
            #expect(assignment != nil)
            let assignmentID = try #require(assignment?.id)

            let requirement = try await AssignmentRequirement.query(on: app.db)
                .filter(\.$assignmentID == assignmentID)
                .first()
            #expect(requirement?.requirementSpec.requiredLanguages.map(\.language) == ["python"])
            #expect(requirement?.requirementSpec.requiredCapabilities.map(\.name) == ["numpy", "pandas"])

        }
    }

    // swiftlint:disable:next function_body_length
    @Test func saveNewAssignmentFinalizesDraftWithGeneratedSuiteFilesVisibleOnEdit() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateRunnerProfiles())
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()

            let now = Date()
            let runnerProfile = RunnerProfile()
            runnerProfile.runnerID = "runner-generated-draft"
            runnerProfile.displayName = "Runner Generated Draft"
            runnerProfile.platform = "linux"
            runnerProfile.architecture = "x86_64"
            runnerProfile.languageVersionsJSON = "[]"
            runnerProfile.capabilitiesJSON = "[]"
            runnerProfile.profileHash = nil
            runnerProfile.lastRegisteredAt = now
            runnerProfile.lastSeenAt = now
            runnerProfile.isActive = true
            try await runnerProfile.save(on: app.db)

            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            let setupID = "setup_generated_suite_finalize"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
            let manifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "worker")
            let notebookDir = app.testSetupsDirectory + "notebooks/\(setupID)/"
            try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
            let assignmentPath = notebookDir + "assignment.ipynb"
            try defaultNotebookData(title: "Generated Suite").write(to: URL(fileURLWithPath: assignmentPath))
            let solutionPath = draftSolutionNotebookPath(
                testSetupsDirectory: app.testSetupsDirectory + "", setupID: setupID)
            try defaultNotebookData(title: "Generated Suite Solution").write(to: URL(fileURLWithPath: solutionPath))

            let setup = APITestSetup(
                id: setupID,
                manifest: manifest,
                zipPath: zipPath,
                notebookPath: assignmentPath,
                courseID: courseID
            )
            try await setup.save(on: app.db)

            let suiteConfig = """
                [
                  {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":"alpha exists","index":0},
                  {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":2,"dependsOn":[],"points":1,"displayName":"beta exists","index":1}
                ]
                """
            let boundary = "Boundary-New-Generated-Suite"
            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", csrf),
                                ("draftID", setupID),
                                ("assignmentName", "Generated Suite Lab"),
                                ("suiteConfig", suiteConfig),
                            ],
                            files: [
                                (
                                    name: "suiteFiles[]", filename: "test_alpha.py", contentType: "text/plain",
                                    data: Data("print('alpha')\n".utf8)
                                ),
                                (
                                    name: "suiteFiles[]", filename: "test_beta.py", contentType: "text/plain",
                                    data: Data("print('beta')\n".utf8)
                                ),
                            ]
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "Generated Suite Lab")
                .first()
            let savedSetup = try await APITestSetup.find(try #require(assignment?.testSetupID), on: app.db)
            let props = try JSONDecoder().decode(
                TestProperties.self,
                from: try #require(savedSetup?.manifest.data(using: .utf8))
            )
            #expect(props.testSuites.map(\.script) == ["test_alpha.py", "test_beta.py"])

            let zipEntries = Set(listZipEntries(zipPath: try #require(savedSetup?.zipPath)))
            #expect(zipEntries.contains("test_alpha.py"), "test_alpha.py missing from zip; entries: \(zipEntries)")
            #expect(zipEntries.contains("test_beta.py"), "test_beta.py missing from zip; entries: \(zipEntries)")

            try await app.asyncTest(
                .GET, "/instructor/\(try #require(assignment?.publicID))/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("test_alpha.py"))
                    #expect(html.contains("test_beta.py"))
                })

        }
    }

    @Test func saveNewAssignmentRequiresCompatibleRunnerForValidation() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateRunnerProfiles())
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            let setupID = "setup_validation_runner_gate"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            var suiteBuffer = ByteBufferAllocator().buffer(capacity: 16)
            suiteBuffer.writeString("print('ok')\n")
            _ = try createRunnerSetupZip(
                suiteFiles: [File(data: suiteBuffer, filename: "test_public.py")],
                suiteConfigJSON: nil,
                zipPath: zipPath
            )
            let manifest = try makeWorkerManifestJSON(
                testSuites: [
                    ConfiguredSuiteEntry(
                        script: "test_public.py",
                        tier: "public",
                        order: 1,
                        dependsOn: [],
                        points: 1,
                        displayName: nil
                    )
                ],
                includeMakefile: false,
                gradingMode: "worker"
            )
            let notebookDir = app.testSetupsDirectory + "notebooks/\(setupID)/"
            try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
            let assignmentPath = notebookDir + "assignment.ipynb"
            try defaultNotebookData(title: "Runner Gate").write(to: URL(fileURLWithPath: assignmentPath))
            let solutionPath = draftSolutionNotebookPath(
                testSetupsDirectory: app.testSetupsDirectory + "", setupID: setupID)
            try defaultNotebookData(title: "Runner Gate Solution").write(to: URL(fileURLWithPath: solutionPath))

            let setup = APITestSetup(
                id: setupID,
                manifest: manifest,
                zipPath: zipPath,
                notebookPath: assignmentPath,
                courseID: courseID
            )
            try await setup.save(on: app.db)

            let boundary = "Boundary-New-Runner-Gate"
            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", csrf),
                                ("draftID", setupID),
                                ("assignmentName", "Needs Matplotlib"),
                                ("requiredLanguagesCSV", "python"),
                                ("requiredCapabilitiesCSV", "matplotlib"),
                            ]
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(location.contains("/instructor/new?"))
                    #expect(
                        location.contains(
                            "No%20compatible%20active%20runner%20is%20available%20to%20validate%20this%20assignment."))
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "Needs Matplotlib")
                .first()
            #expect(assignment == nil)

        }
    }
    // MARK: - Regression tests: assignment creation bug fixes

    /// Bug #2 regression: browser posts suiteFiles with "suiteFiles[]" field name and includes extra
    /// JSON fields in suiteConfig (source, isIncluded, dependsOn: [], displayName: null) that the
    /// server must ignore. Files must land in the zip, the manifest must list them correctly, and
    /// a validation job must be queued when at least one test suite entry is present.
    @Test func saveNewAssignmentWithBrowserFormatSuiteFilesAndFieldName() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateRunnerProfiles())
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()

            // Register an active runner so the validation-runner gate passes.
            let now = Date()
            let runnerProfile = RunnerProfile()
            runnerProfile.runnerID = "runner-browser-fmt"
            runnerProfile.displayName = "Runner Browser Format"
            runnerProfile.platform = "linux"
            runnerProfile.architecture = "x86_64"
            runnerProfile.languageVersionsJSON = "[]"
            runnerProfile.capabilitiesJSON = "[]"
            runnerProfile.profileHash = nil
            runnerProfile.lastRegisteredAt = now
            runnerProfile.lastSeenAt = now
            runnerProfile.isActive = true
            try await runnerProfile.save(on: app.db)

            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
            let boundary = "Boundary-BrowserFmt"
            let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

            // Exact JSON that syncConfig() produces in assignment-new.leaf:
            // extra fields (source, isIncluded) must be silently ignored by SuiteConfigRow.
            let suiteConfig = """
                [
                  {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":null,"index":0},
                  {"source":"upload","isIncluded":true,"isTest":false,"tier":"support","order":2,"dependsOn":[],"points":1,"displayName":null,"index":1}
                ]
                """

            var body = ByteBufferAllocator().buffer(capacity: 4096)
            func field(_ name: String, _ value: String) {
                body.writeString("--\(boundary)\r\n")
                body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                body.writeString(value + "\r\n")
            }
            func file(_ name: String, filename: String, contentType: String, content: String) {
                body.writeString("--\(boundary)\r\n")
                body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                body.writeString("Content-Type: \(contentType)\r\n\r\n")
                body.writeString(content + "\r\n")
            }
            field("_csrf", csrf)
            field("assignmentName", "Browser Format Lab")
            file(
                "assignmentNotebookFile", filename: "assignment.ipynb", contentType: "application/json",
                content: notebook)
            file("solutionNotebookFile", filename: "solution.ipynb", contentType: "application/json", content: notebook)
            // "suiteFiles[]" with brackets — exact field name sent by the browser's FormData API.
            file("suiteFiles[]", filename: "test_bmi.py", contentType: "text/plain", content: "print('test bmi')")
            file("suiteFiles[]", filename: "helpers.py", contentType: "text/plain", content: "# helpers")
            field("suiteConfig", suiteConfig)
            body.writeString("--\(boundary)--\r\n")

            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "Browser Format Lab")
                .first()
            let setupID = try #require(assignment?.testSetupID)
            let setup = try await APITestSetup.find(setupID, on: app.db)

            // Manifest: test_bmi.py (isTest:true, tier:public) → 1 suite entry; helpers.py → support, not listed.
            let props = try JSONDecoder().decode(
                TestProperties.self,
                from: try #require(setup?.manifest.data(using: .utf8))
            )
            #expect(
                props.testSuites.map(\.script) == ["test_bmi.py"],
                "test_bmi.py must be the only test suite entry in manifest")

            // Both files must be present in the zip (support files are stored even if not in manifest).
            let zipEntries = Set(listZipEntries(zipPath: try #require(setup?.zipPath)))
            #expect(zipEntries.contains("test_bmi.py"), "test_bmi.py missing from zip; entries: \(zipEntries)")
            #expect(zipEntries.contains("helpers.py"), "helpers.py missing from zip; entries: \(zipEntries)")

            // Validation job must have been queued (Bug #2: was never queued when DataTransfer files
            // were absent from FormData, causing testSuites to be empty and shouldQueueValidation=false).
            #expect(assignment?.validationStatus == "pending")
            #expect(
                assignment?.validationSubmissionID != nil,
                "validationSubmissionID must be set when suite files are present")

        }
    }

    @Test func editPageShowsUploadedSolutionNotebookFilenameAfterCreate() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateRunnerProfiles())
            try await app.autoMigrate()
            let now = Date()
            let runnerProfile = RunnerProfile()
            runnerProfile.runnerID = "runner-solution-name"
            runnerProfile.displayName = "Runner Solution Name"
            runnerProfile.platform = "linux"
            runnerProfile.architecture = "x86_64"
            runnerProfile.languageVersionsJSON = "[]"
            runnerProfile.capabilitiesJSON = "[]"
            runnerProfile.profileHash = nil
            runnerProfile.lastRegisteredAt = now
            runnerProfile.lastSeenAt = now
            runnerProfile.isActive = true
            try await runnerProfile.save(on: app.db)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            let boundary = "Boundary-Solution-Filename"
            let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
            let solutionName = "BMI Boundary Cases.ipynb"
            let suiteConfig = """
                [
                  {"index":0,"isTest":true,"tier":"public","order":1,"points":1,"displayName":"Smoke test"}
                ]
                """

            try await app.asyncTest(
                .POST, "/instructor/new/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", csrf),
                                ("assignmentName", "Named Solution Lab"),
                                ("suiteConfig", suiteConfig),
                            ],
                            files: [
                                (
                                    name: "assignmentNotebookFile",
                                    filename: "starter.ipynb",
                                    contentType: "application/json",
                                    data: Data(notebook.utf8)
                                ),
                                (
                                    name: "solutionNotebookFile",
                                    filename: solutionName,
                                    contentType: "application/json",
                                    data: Data(notebook.utf8)
                                ),
                                (
                                    name: "suiteFiles[]",
                                    filename: "test_smoke.py",
                                    contentType: "text/plain",
                                    data: Data("print('ok')\n".utf8)
                                ),
                            ]
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let assignment = try await APIAssignment.query(on: app.db)
                .filter(\.$title == "Named Solution Lab")
                .first()
            let validationID = try #require(assignment?.validationSubmissionID)
            let validationSubmission = try await APISubmission.find(validationID, on: app.db)
            #expect(validationSubmission?.filename == solutionName)

            try await app.asyncTest(
                .GET, "/instructor/\(try #require(assignment?.publicID))/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains(solutionName), "\(html)")

                })

        }
    }

    /// v0.4.132 regression (was: bug #1 regression on the legacy
    /// upload-queue path).  After parity PR 1 of #433 dropped the
    /// `suite-list.js` IIFE in favor of `suite-table.js` + the
    /// per-script `POST /draft/scripts` endpoint, the create page
    /// hands generated/edited scripts to the suite table via
    /// `chickadeeAddExistingSuiteScript`.  This test creates a draft
    /// (so the suite-editor block is rendered) and confirms the
    /// page ships the wiring points so the gen-tests panel and the
    /// CodeMirror script editor can stream new scripts straight onto
    /// the suite editor without a multipart bundle.
    @Test func newAssignmentPageWiresGeneratedScriptsThroughSuiteTable() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

            // Create a draft via the same multipart path the UI uses.
            let boundary = "Boundary-Suite-Table-Wiring"
            var redirectLocation: String?
            try await app.asyncTest(
                .POST, "/instructor/new/draft",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", csrf),
                                ("assignmentName", "Suite Table Wiring Lab"),
                                ("draftAction", "create-assignment-notebook"),
                            ]
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    redirectLocation = res.headers.first(name: .location)
                })

            try await app.asyncTest(
                .GET, try #require(redirectLocation),
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        html.contains("/suite-table.js"),
                        "Create page must load suite-table.js once a draft exists (v0.4.132)")
                    #expect(
                        html.contains("chickadeeAddExistingSuiteScript"),
                        """
                        Create page must wire chickadeeAddExistingSuiteScript so \
                        generated/edited scripts land in the suite editor live
                        """
                    )
                    #expect(
                        html.contains("/instructor/new/draft/scripts"),
                        """
                        Generated scripts and the CodeMirror save flow must POST to \
                        the draft scripts endpoint, not bundle into the multipart submit
                        """
                    )
                })

        }
    }

    /// Bug #1 regression: the edit assignment page must include JavaScript for the edit button
    /// on newly uploaded (not-yet-saved) suite file rows.
    @Test func editAssignmentPageContainsEditButtonForUploadedSuiteItems() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let setupID = "setup_edit_upload_btn_reg"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            try arMakeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
                """
            let setup = APITestSetup(
                id: setupID, manifest: manifest, zipPath: zipPath,
                notebookPath: app.testSetupsDirectory + "notebooks/\(setupID)/assignment.ipynb",
                courseID: courseID
            )
            try await setup.save(on: app.db)
            let assignment = APIAssignment(
                publicID: "RGRN01", testSetupID: setupID, title: "Edit Btn Regression",
                dueAt: nil, isOpen: false, courseID: courseID
            )
            try await assignment.save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/RGRN01/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // The rowHTML JS function for new (uploaded) items must contain the edit-button class.
                    #expect(
                        html.contains("suite-edit-upload-btn"),
                        "Edit assignment page must contain suite-edit-upload-btn for newly uploaded suite items")
                })

        }
    }

    /// Bug #3 regression: GET /instructor/script-templates must return a non-empty JSON dict
    /// with keys for both Python and shell template types. The edit page's fetchTemplates()
    /// now calls this endpoint (was previously broken, returning null).
    @Test func scriptTemplatesEndpointReturnsTemplatesForAllTypes() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            try await app.asyncTest(
                .GET, "/instructor/script-templates",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let json = try JSONDecoder().decode([String: String].self, from: Data(res.body.readableBytesView))
                    // Must include at least one Python template and one shell template.
                    #expect(
                        json.keys.contains(where: { $0.hasPrefix("py:") }),
                        "Expected at least one py: key in script templates, got: \(json.keys.sorted())")
                    #expect(
                        json.keys.contains(where: { $0.hasPrefix("sh:") }),
                        "Expected at least one sh: key in script templates, got: \(json.keys.sorted())")
                    // Values must be non-empty script content.
                    for (key, content) in json {
                        #expect(content.isEmpty == false, "Template '\(key)' must have non-empty content")
                    }
                })

        }
    }
}
