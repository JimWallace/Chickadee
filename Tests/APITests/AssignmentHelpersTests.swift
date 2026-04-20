import XCTest
@testable import chickadee_server
import Fluent
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

    private func notebookData(language: String = "python", source: String) -> Data {
        let json = """
        {
          "cells": [
            {
              "cell_type": "code",
              "source": \(String(data: try! JSONEncoder().encode([source]), encoding: .utf8)!)
            }
          ],
          "metadata": {
            "kernelspec": {
              "name": "\(language)",
              "language": "\(language)"
            },
            "language_info": {
              "name": "\(language)"
            }
          },
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
        return Data(json.utf8)
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

    func testSubmissionFilenameForStorageSanitizesAndPreservesExtension() {
        XCTAssertEqual(
            submissionFilenameForStorage(uploadedName: "../Assignment 0 Solution.ipynb", fallback: "solution.ipynb"),
            "Assignment 0 Solution.ipynb"
        )

        XCTAssertEqual(
            submissionFilenameForStorage(uploadedName: "C:\\\\fakepath\\\\dna.py", fallback: "solution.ipynb"),
            "C   fakepath  dna.py"
        )

        XCTAssertEqual(
            submissionFilenameForStorage(uploadedName: "   ", fallback: "solution.ipynb"),
            "solution.ipynb"
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

    func testDetectRequirementSuggestionsIgnoresSolutionNotebookImports() throws {
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("detect-requirements-\(UUID().uuidString).zip")
            .path
        try makeZip(at: zipPath, entries: [
            (name: "tests/run.sh", content: "#!/bin/bash\necho ok\n")
        ])

        let setup = APITestSetup(
            id: "setup_detect_requirements",
            manifest: "{}",
            zipPath: zipPath,
            notebookPath: "/tmp/assignment.ipynb",
            courseID: UUID()
        )

        let suggestions = detectRequirementSuggestions(
            assignmentNotebookData: notebookData(source: "import pandas\n"),
            solutionNotebookData: notebookData(source: "import scipy\nimport matplotlib\n"),
            setup: setup
        )

        XCTAssertEqual(suggestions.languages, ["python"])
        XCTAssertEqual(suggestions.capabilities, ["pandas", "shell-bash"])
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

    func testBuildSuiteEntriesFallsBackToExtensionlessShellShebangScripts() throws {
        let suiteFiles = [
            makeFile(named: "01_shell", contents: "#!/bin/sh\necho ok\n"),
            makeFile(named: "02_bash", contents: "#!/usr/bin/env bash\necho ok\n"),
            makeFile(named: "03_notes", contents: "echo support but no shebang\n"),
            makeFile(named: "04_python.py", contents: "print('ok')\n")
        ]

        let entries = try buildSuiteEntries(
            suiteFiles: suiteFiles,
            storedNameByIndex: [
                0: "01_shell",
                1: "02_bash",
                2: "03_notes",
                3: "04_python.py"
            ],
            suiteConfigJSON: nil
        )

        XCTAssertEqual(entries.map(\.script), ["01_shell", "02_bash", "04_python.py"])
        XCTAssertTrue(entries.allSatisfy { $0.tier == "public" })
    }

    func testBuildSuiteEntriesTreatsAnyNonSupportTierAsATestWhenIsTestIsMissing() throws {
        let suiteFiles = [
            makeFile(named: "assignment.ipynb", contents: "{}"),
            makeFile(named: "test_q1.py", contents: "print('q1')"),
            makeFile(named: "notes.txt", contents: "support")
        ]

        let configJSON = """
        [
          {"index":0,"tier":"support","order":1},
          {"index":1,"tier":"release","order":2,"points":2},
          {"index":2,"tier":"support","order":3}
        ]
        """

        let entries = try buildSuiteEntries(
            suiteFiles: suiteFiles,
            storedNameByIndex: [
                0: "assignment.ipynb",
                1: "test_q1.py",
                2: "notes.txt"
            ],
            suiteConfigJSON: configJSON
        )

        XCTAssertEqual(entries.map(\.script), ["test_q1.py"])
        XCTAssertEqual(entries.first?.tier, "release")
        XCTAssertEqual(entries.first?.points, 2)
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

    func testRemoveMaterializedNotebookFilesDeletesLegacyNotebookArtifactsForSetup() async throws {
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

        try await withApp(try await Application.make(.testing)) { app in
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

    func testDeadlineOverrideHelpersRespectPastAndFutureDueDates() {
        let past = Date().addingTimeInterval(-60)
        let future = Date().addingTimeInterval(60)

        XCTAssertTrue(deadlineOverrideValueForInstructorOpen(dueAt: past))
        XCTAssertFalse(deadlineOverrideValueForInstructorOpen(dueAt: future))
        XCTAssertFalse(deadlineOverrideValueForInstructorOpen(dueAt: nil))

        XCTAssertFalse(normalizedDeadlineOverrideAfterDueDateChange(dueAt: future, existingOverride: true))
        XCTAssertFalse(normalizedDeadlineOverrideAfterDueDateChange(dueAt: nil, existingOverride: true))
        XCTAssertTrue(normalizedDeadlineOverrideAfterDueDateChange(dueAt: past, existingOverride: true))
        XCTAssertFalse(normalizedDeadlineOverrideAfterDueDateChange(dueAt: past, existingOverride: false))
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

    func testResolveEditSuiteFilesTreatsLegacyUncheckedRowsAsSupport() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-edit-legacy-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        try makeZip(at: zipPath, entries: [
            ("test_q1.py", "print('q1')"),
            ("notes.txt", "notes")
        ])

        let resolved = try resolveEditSuiteFiles(
            setupZipPath: zipPath,
            setupManifestJSON: "{}",
            uploadedSuiteFiles: [],
            suiteConfigJSON: """
            [
              {"source":"existing","name":"test_q1.py","isTest":false,"tier":"public","order":1},
              {"source":"existing","name":"notes.txt","tier":"support","order":2}
            ]
            """
        )

        let configData = try XCTUnwrap(resolved.reindexedSuiteConfigJSON?.data(using: .utf8))
        let rows = try JSONDecoder().decode([DecodedReindexedSuiteConfigRow].self, from: configData)
        XCTAssertEqual(rows.map(\.tier), ["support", "support"])
        XCTAssertEqual(rows.map(\.isTest), [false, false])
    }

    func testNormalizeTierAndInferredOrderHandleFallbackCases() {
        XCTAssertEqual(normalizeTier(nil), "public")
        XCTAssertEqual(normalizeTier("VISIBLE"), "public")
        XCTAssertEqual(normalizeTier("support"), "support")
        XCTAssertEqual(normalizeTier("secret"), "secret")
        XCTAssertEqual(normalizeTier("release"), "release")
        XCTAssertEqual(normalizeTier("mystery"), "public")
        XCTAssertEqual(normalizeTier("public", isTest: false), "support")
        XCTAssertEqual(normalizeTier(nil, isTest: false), "support")

        XCTAssertEqual(inferredOrder(from: "12_release.py"), 12)
        XCTAssertEqual(inferredOrder(from: "007_secret.py"), 7)
        XCTAssertNil(inferredOrder(from: "notes.txt"))
    }

    func testCreateRunnerSetupZipAllowsConfigsWithoutSelectedTests() throws {
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

        let setupZip = try createRunnerSetupZip(
            suiteFiles: suiteFiles,
            suiteConfigJSON: configJSON,
            zipPath: zipPath
        )

        XCTAssertEqual(setupZip.testSuites.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath))
    }

    func testCreateRunnerSetupZipReplacesExistingArchiveInsteadOfMergingRemovedFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-setup-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path

        _ = try createRunnerSetupZip(
            suiteFiles: [
                makeFile(named: "keep.py", contents: "print('keep')"),
                makeFile(named: "remove.py", contents: "print('remove')")
            ],
            suiteConfigJSON: """
            [
              {"index":0,"isTest":true,"tier":"public","points":1},
              {"index":1,"isTest":true,"tier":"public","points":1}
            ]
            """,
            zipPath: zipPath
        )

        _ = try createRunnerSetupZip(
            suiteFiles: [
                makeFile(named: "keep.py", contents: "print('keep-updated')")
            ],
            suiteConfigJSON: """
            [
              {"index":0,"isTest":true,"tier":"public","points":1}
            ]
            """,
            zipPath: zipPath
        )

        let entries = Set(listZipEntries(zipPath: zipPath))
        XCTAssertEqual(entries, ["keep.py"])
        XCTAssertNil(extractZipEntry(zipPath: zipPath, entryName: "remove.py"))
        let keepData = try XCTUnwrap(extractZipEntry(zipPath: zipPath, entryName: "keep.py"))
        XCTAssertEqual(String(data: keepData, encoding: .utf8), "print('keep-updated')")
    }

    // MARK: - mergeExistingFilesIntoSuiteFiles

    func testMergeExistingFilesAddsNamedDraftFilesAndRewritesRowsWithIndices() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-existing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("draft.zip").path
        try makeZip(at: zipPath, entries: [
            ("test_existing.py", "print('existing')"),
            ("helper.txt", "support data")
        ])

        // Config as sent by syncConfig() when user has one 'existing' item and one generated 'upload' item.
        // This is the detect-functions scenario: 'existing' row has no 'index', causing SuiteConfigRow
        // decode to fail and the existing test to be dropped from the manifest.
        let configJSON = """
        [
          {"source":"existing","name":"test_existing.py","isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":null},
          {"source":"upload","index":0,"isTest":true,"tier":"public","order":2,"dependsOn":[],"points":1,"displayName":null}
        ]
        """
        let uploadedFile = makeFile(named: "test_generated.py", contents: "print('generated')")

        let (merged, updatedJSON) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: [uploadedFile],
            suiteConfigJSON: configJSON,
            draftZipPath: zipPath
        )

        // Both files should now be in the merged list.
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(where: { $0.filename == "test_generated.py" }))
        XCTAssertTrue(merged.contains(where: { $0.filename == "test_existing.py" }))

        // Updated JSON must use numeric 'index' for all rows so SuiteConfigRow decodes cleanly.
        let updatedData = try XCTUnwrap(updatedJSON?.data(using: .utf8))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedData) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNotNil(row["index"], "Every row must have a numeric index after merging")
            XCTAssertNil(row["name"], "'name' key should be removed after converting to index-based row")
        }
    }

    func testMergeExistingFilesPassesThroughPureUploadConfig() throws {
        // When no 'existing' rows are present the file list and row count should be unchanged.
        let configJSON = """
        [{"source":"upload","index":0,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1}]
        """
        let file = makeFile(named: "test.py", contents: "pass")

        let (merged, updatedJSON) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: [file],
            suiteConfigJSON: configJSON,
            draftZipPath: nil
        )

        XCTAssertEqual(merged.count, 1)
        // Verify the row is unchanged: still one index-based row with the correct fields.
        let data = try XCTUnwrap(updatedJSON?.data(using: .utf8))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["index"] as? Int, 0)
        XCTAssertNil(rows[0]["name"])
    }

    func testDetectFunctionsRoundTripIncludesBothExistingAndGeneratedTests() throws {
        // Full integration of the detect-functions save path: an assignment draft has an existing
        // test file; the instructor generates an additional test via "Detect Functions"; on save the
        // manifest must include BOTH the existing test and the newly generated one.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("detect-functions-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let draftZipPath = tempRoot.appendingPathComponent("draft.zip").path
        try makeZip(at: draftZipPath, entries: [
            ("test_existing.py", "print('existing test')")
        ])

        let outputZipPath = tempRoot.appendingPathComponent("output.zip").path

        // Simulate the config JSON produced by syncConfig() with one 'existing' and one 'upload' row.
        let configJSON = """
        [
          {"source":"existing","name":"test_existing.py","isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":null},
          {"source":"upload","index":0,"isTest":true,"tier":"public","order":2,"dependsOn":[],"points":1,"displayName":null}
        ]
        """
        let generatedFile = makeFile(named: "test_generated.py", contents: "print('generated test')")

        let (mergedFiles, mergedConfig) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: [generatedFile],
            suiteConfigJSON: configJSON,
            draftZipPath: draftZipPath
        )
        let package = try createRunnerSetupZip(
            suiteFiles: mergedFiles,
            suiteConfigJSON: mergedConfig,
            zipPath: outputZipPath
        )

        let testScripts = Set(package.testSuites.map(\.script))
        XCTAssertTrue(testScripts.contains("test_existing.py"), "Existing draft test must survive the save")
        XCTAssertTrue(testScripts.contains("test_generated.py"), "Generated test must be included in manifest")
        XCTAssertEqual(package.testSuites.count, 2)
    }

    func testPracticeLabBrowserSetupRoundTripPreservesAllSuiteFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("practice-lab-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let originalZipPath = tempRoot.appendingPathComponent("practice.zip").path
        try makeZip(at: originalZipPath, entries: [
            ("assignment.ipynb", "{}"),
            ("test.properties.json", #"{"gradingMode":"browser"}"#),
            ("test_q1_bmi.py", "print('q1')"),
            ("test_q2_bp.py", "print('q2')"),
            ("test_q3_hr_zone.py", "print('q3')"),
            ("test_q4_patients.py", "print('q4')"),
            ("test_q5_dose.py", "print('q5')"),
            ("test_q6_risk.py", "print('q6')")
        ])

        let manifest = """
        {
          "schemaVersion": 1,
          "gradingMode": "browser",
          "requiredFiles": [],
          "testSuites": [
            {"tier":"public","script":"test_q1_bmi.py"},
            {"tier":"public","script":"test_q2_bp.py"},
            {"tier":"public","script":"test_q3_hr_zone.py"},
            {"tier":"public","script":"test_q4_patients.py"},
            {"tier":"release","script":"test_q5_dose.py"},
            {"tier":"release","script":"test_q6_risk.py"}
          ],
          "timeLimitSeconds": 10,
          "makefile": null,
          "starterNotebook": "assignment.ipynb"
        }
        """

        let resolved = try resolveEditSuiteFiles(
            setupZipPath: originalZipPath,
            setupManifestJSON: manifest,
            uploadedSuiteFiles: [],
            suiteConfigJSON: nil
        )

        XCTAssertEqual(
            resolved.files.map(\.filename),
            [
                "test.properties.json",
                "test_q1_bmi.py",
                "test_q2_bp.py",
                "test_q3_hr_zone.py",
                "test_q4_patients.py",
                "test_q5_dose.py",
                "test_q6_risk.py"
            ]
        )

        let rebuiltZipPath = tempRoot.appendingPathComponent("rebuilt.zip").path
        _ = try createRunnerSetupZip(
            suiteFiles: resolved.files,
            suiteConfigJSON: resolved.reindexedSuiteConfigJSON,
            zipPath: rebuiltZipPath
        )

        let setup = APITestSetup(
            id: "practice_lab",
            manifest: manifest,
            zipPath: rebuiltZipPath,
            notebookPath: tempRoot.appendingPathComponent("assignment.ipynb").path,
            courseID: UUID()
        )
        try Data("{}".utf8).write(to: URL(fileURLWithPath: setup.notebookPath ?? ""))

        let result = currentSetupFiles(for: setup, assignmentID: "asg_practice", hasValidationSolution: false)

        XCTAssertEqual(
            result.existingSuiteRows.map(\.name),
            [
                "test_q1_bmi.py",
                "test_q2_bp.py",
                "test_q3_hr_zone.py",
                "test_q4_patients.py",
                "test_q5_dose.py",
                "test_q6_risk.py",
                "test.properties.json"
            ]
        )
        XCTAssertEqual(result.existingSuiteRows.last?.tier, "support")
    }
}
