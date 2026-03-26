import XCTest
@testable import chickadee_server
import Core
import Vapor

final class AssignmentHelpersTests: XCTestCase {

    private struct DecodedReindexedSuiteConfigRow: Decodable {
        let index: Int
        let isTest: Bool
        let tier: String
        let order: Int?
        let dependsOn: [String]?
        let points: Int
        let displayName: String?
    }

    private func makeFile(named name: String, contents: String) -> File {
        var buffer = ByteBufferAllocator().buffer(capacity: contents.utf8.count)
        buffer.writeString(contents)
        return File(data: buffer, filename: name)
    }

    private func makeZip(at zipPath: String, entries: [(name: String, content: String)]) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assignment-helper-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in entries {
            let path = tempDir.appendingPathComponent(entry.name)
            let parent = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(entry.content.utf8).write(to: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", "-r", zipPath, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip should succeed")
    }

    func testSanitizedAssignmentReturnPathAcceptsOnlyInstructorScopedPaths() {
        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "/instructor/asg123",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123"
        )

        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "/instructor/asg123/submissions",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123/submissions"
        )

        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "/instructor/other/submissions",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123/edit"
        )

        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "https://example.com/escape",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123/edit"
        )
    }

    func testNotebookFilenameForStorageSanitizesAndNormalizesExtension() {
        XCTAssertEqual(
            notebookFilenameForStorage(uploadedName: "../Unit 1: Intro", fallback: "assignment.ipynb"),
            "Unit 1  Intro.ipynb"
        )

        XCTAssertEqual(
            notebookFilenameForStorage(uploadedName: "lesson.ipynb", fallback: "assignment.ipynb"),
            "lesson.ipynb"
        )

        XCTAssertEqual(
            notebookFilenameForStorage(uploadedName: "   ", fallback: "starter.ipynb"),
            "starter.ipynb"
        )
    }

    func testManifestDependentsReturnsScriptsThatReferenceDependency() {
        let manifest = try! makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "01_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 2,
                    dependsOn: ["01_public.py"],
                    points: 2,
                    displayName: "Release"
                ),
                ConfiguredSuiteEntry(
                    script: "03_secret.py",
                    tier: "secret",
                    order: 3,
                    dependsOn: ["01_public.py"],
                    points: 3,
                    displayName: nil
                )
            ],
            includeMakefile: false
        )

        XCTAssertEqual(
            manifestDependents(manifestJSON: manifest, filename: "01_public.py"),
            ["02_release.py", "03_secret.py"]
        )
        XCTAssertEqual(manifestDependents(manifestJSON: manifest, filename: "missing.py"), [])
    }

    func testUpdateManifestAddingScriptPreservesMetadataAndAppendsEntry() throws {
        let original = """
        {
          "schemaVersion": 1,
          "gradingMode": "browser",
          "requiredFiles": [],
          "testSuites": [
            {"tier": "public", "script": "01_public.py"}
          ],
          "timeLimitSeconds": 10,
          "makefile": {"target": null},
          "starterNotebook": "starter.ipynb"
        }
        """

        let updated = try XCTUnwrap(
            updateManifestAddingScript(
                manifestJSON: original,
                entry: ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 99,
                    dependsOn: ["01_public.py"],
                    points: 2,
                    displayName: "Release tests"
                )
            )
        )

        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        XCTAssertEqual(props.gradingMode, .browser)
        XCTAssertEqual(props.starterNotebook, "starter.ipynb")
        XCTAssertNotNil(props.makefile)
        XCTAssertEqual(props.testSuites.map(\.script), ["01_public.py", "02_release.py"])
        XCTAssertEqual(props.testSuites.last?.dependsOn, ["01_public.py"])
        XCTAssertEqual(props.testSuites.last?.points, 2)
        XCTAssertEqual(props.testSuites.last?.name, "Release tests")
    }

    func testUpdateManifestRemovingScriptClearsDependencyReferences() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "01_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 2,
                    dependsOn: ["01_public.py"],
                    points: 1,
                    displayName: nil
                )
            ],
            includeMakefile: false
        )

        let updated = try XCTUnwrap(
            updateManifestRemovingScript(manifestJSON: original, filename: "01_public.py")
        )

        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        XCTAssertEqual(props.testSuites.map(\.script), ["02_release.py"])
        XCTAssertEqual(props.testSuites.first?.dependsOn, [])
    }

    func testMakeWorkerManifestJSONTopologicallySortsSuitesAndOmitsDefaults() throws {
        let manifest = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "03_secret.py",
                    tier: "secret",
                    order: 3,
                    dependsOn: ["02_release.py"],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "01_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 2,
                    dependsOn: ["01_public.py"],
                    points: 4,
                    displayName: "Release tests"
                )
            ],
            includeMakefile: true,
            gradingMode: "worker",
            starterNotebook: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
        )
        let suites = try XCTUnwrap(object["testSuites"] as? [[String: Any]])

        XCTAssertEqual(suites.map { $0["script"] as? String }, ["01_public.py", "02_release.py", "03_secret.py"])
        XCTAssertNil(object["starterNotebook"])
        XCTAssertNotNil(object["makefile"])
        XCTAssertNil(suites[0]["points"], "Default weight should be omitted")
        XCTAssertNil(suites[0]["dependsOn"], "Empty dependencies should be omitted")
        XCTAssertEqual(suites[1]["points"] as? Int, 4)
        XCTAssertEqual(suites[1]["name"] as? String, "Release tests")
    }

    func testBuildSuiteEntriesUsesExplicitSuiteConfigOrderingAndMetadata() throws {
        let suiteFiles = [
            makeFile(named: "01_public.py", contents: "print('public')"),
            makeFile(named: "notes.txt", contents: "support"),
            makeFile(named: "02_secret.py", contents: "print('secret')")
        ]

        let configJSON = """
        [
          {"index":2,"isTest":true,"tier":"secret","order":7,"dependsOn":["01_public.py"],"points":3,"displayName":"Secret"},
          {"index":1,"isTest":false,"tier":"support","order":2},
          {"index":0,"isTest":true,"tier":"public","order":1}
        ]
        """

        let entries = try buildSuiteEntries(
            suiteFiles: suiteFiles,
            storedNameByIndex: [
                0: "01_public.py",
                1: "notes.txt",
                2: "02_secret.py"
            ],
            suiteConfigJSON: configJSON
        )

        XCTAssertEqual(entries.map(\.script), ["01_public.py", "02_secret.py"])
        XCTAssertEqual(entries[1].tier, "secret")
        XCTAssertEqual(entries[1].dependsOn, ["01_public.py"])
        XCTAssertEqual(entries[1].points, 3)
        XCTAssertEqual(entries[1].displayName, "Secret")
    }

    func testBuildSuiteEntriesFallsBackToLikelyTestFilesAndInferredOrder() throws {
        let suiteFiles = [
            makeFile(named: "20_hidden.py", contents: "print('b')"),
            makeFile(named: "readme.txt", contents: "ignore"),
            makeFile(named: "01_public.sh", contents: "echo test")
        ]

        let entries = try buildSuiteEntries(
            suiteFiles: suiteFiles,
            storedNameByIndex: [
                0: "20_hidden.py",
                1: "readme.txt",
                2: "01_public.sh"
            ],
            suiteConfigJSON: nil
        )

        XCTAssertEqual(entries.map(\.script), ["01_public.sh", "20_hidden.py"])
        XCTAssertTrue(entries.allSatisfy { $0.tier == "public" })
    }

    func testCreateRunnerSetupZipDeduplicatesStoredNamesAndDetectsMakefile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        let suiteFiles = [
            makeFile(named: "tests.py", contents: "print('one')"),
            makeFile(named: "nested/tests.py", contents: "print('two')"),
            makeFile(named: "Makefile", contents: "all:\n\t@echo hi\n")
        ]
        let configJSON = """
        [
          {"index":0,"isTest":true,"tier":"public","order":1},
          {"index":1,"isTest":true,"tier":"secret","order":2},
          {"index":2,"isTest":false,"tier":"support","order":3}
        ]
        """

        let package = try createRunnerSetupZip(
            suiteFiles: suiteFiles,
            suiteConfigJSON: configJSON,
            zipPath: zipPath
        )

        XCTAssertTrue(package.hasMakefile)
        XCTAssertEqual(package.testSuites.map(\.script), ["tests.py", "tests-2.py"])
        XCTAssertEqual(package.testSuites.map(\.tier), ["public", "secret"])

        let zipEntries = Set(listZipEntries(zipPath: zipPath))
        XCTAssertTrue(zipEntries.contains("tests.py"))
        XCTAssertTrue(zipEntries.contains("tests-2.py"))
        XCTAssertTrue(zipEntries.contains("Makefile"))
    }

    func testExtractSupportFilesToSharedDirectoryRefreshesAndFiltersReservedEntries() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        try makeZip(at: zipPath, entries: [
            ("assignment.ipynb", "{}"),
            ("solution.ipynb", "{}"),
            ("tests.py", "print('test')"),
            ("data/sample.csv", "a,b\n1,2\n"),
            ("notes.txt", "hello")
        ])

        let testSetupsDirectory = tempRoot.appendingPathComponent("testsetups").path + "/"
        let sharedDir = testSetupsDirectory + "shared/setup_123/"
        try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        try "stale".write(toFile: sharedDir + "stale.txt", atomically: true, encoding: .utf8)

        extractSupportFilesToSharedDirectory(
            zipPath: zipPath,
            setupID: "setup_123",
            testSuiteScripts: ["tests.py"],
            testSetupsDirectory: testSetupsDirectory
        )

        let extracted = Set(try FileManager.default.subpathsOfDirectory(atPath: sharedDir))
        XCTAssertTrue(extracted.contains("data/sample.csv"))
        XCTAssertTrue(extracted.contains("notes.txt"))
        XCTAssertFalse(extracted.contains("tests.py"))
        XCTAssertFalse(extracted.contains("assignment.ipynb"))
        XCTAssertFalse(extracted.contains("solution.ipynb"))
        XCTAssertFalse(extracted.contains("stale.txt"))
    }

    func testRemoveMaterializedNotebookFilesDeletesLegacyNotebookArtifactsForSetup() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("materialized-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let publicDirectory = tempRoot.appendingPathComponent("public").path + "/"
        let roots = [
            "files/",
            "jupyterlite/files/",
            "jupyterlite/lab/files/",
            "jupyterlite/notebooks/files/"
        ]
        for root in roots {
            try FileManager.default.createDirectory(
                atPath: publicDirectory + root,
                withIntermediateDirectories: true
            )
            try "{}".write(
                toFile: publicDirectory + root + "setup_123-work.ipynb",
                atomically: true,
                encoding: .utf8
            )
            try "{}".write(
                toFile: publicDirectory + root + "other-work.ipynb",
                atomically: true,
                encoding: .utf8
            )
            try "keep".write(
                toFile: publicDirectory + root + "setup_123.txt",
                atomically: true,
                encoding: .utf8
            )
        }

        let app = Application(.testing)
        defer { app.shutdown() }
        app.directory.publicDirectory = publicDirectory

        let req = Request(application: app, on: app.eventLoopGroup.next())
        removeMaterializedNotebookFiles(req: req, setupID: "setup_123")

        for root in roots {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: publicDirectory + root + "setup_123-work.ipynb")
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: publicDirectory + root + "other-work.ipynb")
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: publicDirectory + root + "setup_123.txt")
            )
        }
    }

    func testGradePercentFromCollectionJSONPrefersWeightedPointsAndFallsBackToCounts() {
        XCTAssertEqual(
            gradePercentFromCollectionJSON(
                #"{"earnedPoints":7,"totalPoints":8,"passCount":1,"totalTests":4}"#
            ),
            88
        )

        XCTAssertEqual(
            gradePercentFromCollectionJSON(
                #"{"passCount":3,"totalTests":4}"#
            ),
            75
        )

        XCTAssertNil(gradePercentFromCollectionJSON(#"{"passCount":0,"totalTests":0}"#))
        XCTAssertNil(gradePercentFromCollectionJSON("not-json"))
    }

    func testCsvEscapedQuotesOnlyWhenNeeded() {
        XCTAssertEqual(csvEscaped("plain"), "plain")
        XCTAssertEqual(csvEscaped("last, first"), "\"last, first\"")
        XCTAssertEqual(csvEscaped("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testInferNameFromStudentIDParsesCommaSeparatedNames() {
        XCTAssertEqual(inferNameFromStudentID("Doe, Jane").surname, "Doe")
        XCTAssertEqual(inferNameFromStudentID("Doe, Jane").givenNames, "Jane")
        XCTAssertEqual(inferNameFromStudentID("  ").surname, "—")
        XCTAssertEqual(inferNameFromStudentID("jdoe123").givenNames, "—")
    }

    func testDefaultNotebookDataEmbedsAssignmentTitle() throws {
        let data = defaultNotebookData(title: "Lab \"1\"")
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#"# Lab \"1\""#))
        XCTAssertTrue(json.contains(#""nbformat": 4"#))
    }

    func testContentTypeMapsKnownTextAndNotebookTypes() {
        XCTAssertEqual(contentType(for: "assignment.ipynb"), .json)
        XCTAssertEqual(contentType(for: "notes.md"), .plainText)
        XCTAssertEqual(contentType(for: "archive.bin").serialize(), "application/octet-stream")
    }

    func testUrlEncodeEscapesSpacesAndReservedCharacters() {
        XCTAssertEqual(urlEncode("hello world.py"), "hello%20world.py")
        XCTAssertEqual(urlEncode("data/results?.csv"), "data%2Fresults%3F.csv")
    }

    func testParseDueDateAndLocalInputStringHandleSupportedFormats() {
        let isoDate = parseDueDate("2026-03-26T14:30:00Z")
        XCTAssertNotNil(isoDate)

        let localDate = parseDueDate("2026-03-26T14:30")
        XCTAssertEqual(dueAtLocalInputString(localDate), "2026-03-26T14:30")

        XCTAssertNil(parseDueDate(""))
        XCTAssertNil(parseDueDate("not-a-date"))
        XCTAssertEqual(dueAtLocalInputString(nil), "")
    }

    func testCurrentSetupFilesUsesManifestOrderingAndSolutionFallbacks() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-setup-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        let notebookPath = tempRoot.appendingPathComponent("starter.ipynb").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: notebookPath))
        try makeZip(at: zipPath, entries: [
            ("assignment.ipynb", "{}"),
            ("02_release.py", "print('release')"),
            ("notes.txt", "notes"),
            ("01_public.py", "print('public')")
        ])

        let setup = APITestSetup(
            id: "setup_1",
            manifest: """
            {
              "schemaVersion": 1,
              "gradingMode": "worker",
              "requiredFiles": [],
              "testSuites": [
                {"tier":"public","script":"01_public.py","name":"Public test"},
                {"tier":"release","script":"02_release.py","dependsOn":["01_public.py"],"points":3}
              ],
              "timeLimitSeconds": 10,
              "makefile": null
            }
            """,
            zipPath: zipPath,
            notebookPath: notebookPath,
            courseID: UUID()
        )

        let result = currentSetupFiles(for: setup, assignmentID: "asg123", hasValidationSolution: true)

        XCTAssertEqual(result.assignmentFile.name, "starter.ipynb")
        XCTAssertEqual(result.assignmentFile.url, "/instructor/asg123/files/notebook")
        XCTAssertEqual(result.solutionFile?.name, "solution.ipynb")
        XCTAssertEqual(result.solutionFile?.url, "/instructor/asg123/files/solution")
        XCTAssertEqual(result.existingSuiteRows.map(\.name), ["01_public.py", "02_release.py", "notes.txt"])
        XCTAssertEqual(result.existingSuiteRows[0].displayName, "Public test")
        XCTAssertEqual(result.existingSuiteRows[1].dependsOn, ["01_public.py"])
        XCTAssertEqual(result.existingSuiteRows[1].points, 3)
        XCTAssertEqual(result.existingSuiteRows[2].tier, "support")
    }

    func testResolveEditSuiteFilesFallbackPreservesExistingAndAppendsUploads() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-edit-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        try makeZip(at: zipPath, entries: [
            ("assignment.ipynb", "{}"),
            ("solution.ipynb", "{}"),
            ("02_release.py", "print('release')"),
            ("readme.txt", "support")
        ])

        let uploads = [
            makeFile(named: "10_new.py", contents: "print('new')"),
            makeFile(named: "extra.txt", contents: "extra")
        ]

        let resolved = try resolveEditSuiteFiles(
            setupZipPath: zipPath,
            setupManifestJSON: """
            {
              "schemaVersion": 1,
              "gradingMode": "worker",
              "requiredFiles": [],
              "testSuites": [
                {"tier":"release","script":"02_release.py","points":2}
              ],
              "timeLimitSeconds": 10,
              "makefile": null
            }
            """,
            uploadedSuiteFiles: uploads,
            suiteConfigJSON: nil
        )

        XCTAssertEqual(resolved.files.map(\.filename), ["02_release.py", "readme.txt", "10_new.py", "extra.txt"])
        let configData = try XCTUnwrap(resolved.reindexedSuiteConfigJSON?.data(using: .utf8))
        let rows = try JSONDecoder().decode([DecodedReindexedSuiteConfigRow].self, from: configData)
        XCTAssertEqual(rows.map(\.tier), ["release", "support", "public", "support"])
        XCTAssertEqual(rows.map(\.isTest), [true, false, true, false])
        XCTAssertEqual(rows[0].points, 2)
    }

    func testResolveEditSuiteFilesExplicitConfigFiltersAndSanitizesSources() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-edit-explicit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        try makeZip(at: zipPath, entries: [
            ("existing.py", "print('existing')"),
            ("keep.txt", "keep")
        ])

        let uploads = [
            makeFile(named: "nested/new.py", contents: "print('upload')"),
            makeFile(named: "", contents: "fallback name")
        ]

        let resolved = try resolveEditSuiteFiles(
            setupZipPath: zipPath,
            setupManifestJSON: "{}",
            uploadedSuiteFiles: uploads,
            suiteConfigJSON: """
            [
              {"source":"existing","name":"existing.py","isTest":true,"tier":"SECRET","order":9,"dependsOn":["dep.py"],"points":4,"displayName":"Existing"},
              {"source":"upload","index":0,"isTest":true,"tier":"release","order":2},
              {"source":"upload","index":1,"isTest":false,"tier":"support","isIncluded":false},
              {"source":"existing","name":"../bad.py","isTest":true,"tier":"public"},
              {"source":"unknown","name":"skip.py","isTest":true}
            ]
            """
        )

        XCTAssertEqual(resolved.files.map(\.filename), ["existing.py", "new.py"])
        let configData = try XCTUnwrap(resolved.reindexedSuiteConfigJSON?.data(using: .utf8))
        let rows = try JSONDecoder().decode([DecodedReindexedSuiteConfigRow].self, from: configData)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].tier, "secret")
        XCTAssertEqual(rows[0].dependsOn, ["dep.py"])
        XCTAssertEqual(rows[0].points, 4)
        XCTAssertEqual(rows[0].displayName, "Existing")
        XCTAssertEqual(rows[1].tier, "release")
        XCTAssertEqual(rows[1].isTest, true)
    }

    func testNormalizeTierAndInferredOrderHandleFallbackCases() {
        XCTAssertEqual(normalizeTier(nil), "public")
        XCTAssertEqual(normalizeTier("VISIBLE"), "public")
        XCTAssertEqual(normalizeTier("secret"), "secret")
        XCTAssertEqual(normalizeTier("release"), "release")
        XCTAssertEqual(normalizeTier("mystery"), "public")

        XCTAssertEqual(inferredOrder(from: "12_release.py"), 12)
        XCTAssertEqual(inferredOrder(from: "007_secret.py"), 7)
        XCTAssertNil(inferredOrder(from: "notes.txt"))
    }

    func testCreateRunnerSetupZipRejectsConfigsWithoutSelectedTests() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-setup-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        let suiteFiles = [
            makeFile(named: "10_hidden.py", contents: "print('hidden')")
        ]
        let configJSON = """
            [
              {
                "index": 0,
                "tier": "secret",
                "isTest": false,
                "points": 5
              }
            ]
            """

        do {
            _ = try createRunnerSetupZip(
                suiteFiles: suiteFiles,
                suiteConfigJSON: configJSON,
                zipPath: zipPath
            )
            XCTFail("Expected createRunnerSetupZip to reject configs without selected tests")
        } catch let error as AbortError {
            XCTAssertEqual(error.status, .badRequest)
            XCTAssertEqual(error.reason, "Select at least one test file in the suite file list")
        }
    }
}
