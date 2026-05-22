// Tests/APITests/AssignmentHelpersManifestTests.swift
//
// Split from AssignmentHelpersTests.swift.  See AssignmentHelpersTestCase.swift
// for shared helpers (makeFile, makeZip, notebookData).

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

final class AssignmentHelpersManifestTests {

    @Test func sanitizedAssignmentReturnPathAcceptsOnlyInstructorScopedPaths() {
        #expect(
            sanitizedAssignmentReturnPath(
                "/instructor/asg123",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ) == "/instructor/asg123")

        #expect(
            sanitizedAssignmentReturnPath(
                "/instructor/asg123/submissions",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ) == "/instructor/asg123/submissions")

        #expect(
            sanitizedAssignmentReturnPath(
                "/instructor/other/submissions",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ) == "/instructor/asg123/edit")

        #expect(
            sanitizedAssignmentReturnPath(
                "https://example.com/escape",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ) == "/instructor/asg123/edit")
    }

    @Test func notebookFilenameForStorageSanitizesAndNormalizesExtension() {
        #expect(
            notebookFilenameForStorage(uploadedName: "../Unit 1: Intro", fallback: "assignment.ipynb")
                == "Unit 1  Intro.ipynb")

        #expect(
            notebookFilenameForStorage(uploadedName: "lesson.ipynb", fallback: "assignment.ipynb") == "lesson.ipynb")

        #expect(notebookFilenameForStorage(uploadedName: "   ", fallback: "starter.ipynb") == "starter.ipynb")
    }

    @Test func submissionFilenameForStorageSanitizesAndPreservesExtension() {
        #expect(
            submissionFilenameForStorage(uploadedName: "../Assignment 0 Solution.ipynb", fallback: "solution.ipynb")
                == "Assignment 0 Solution.ipynb")

        #expect(
            submissionFilenameForStorage(uploadedName: "C:\\\\fakepath\\\\dna.py", fallback: "solution.ipynb")
                == "C   fakepath  dna.py")

        #expect(submissionFilenameForStorage(uploadedName: "   ", fallback: "solution.ipynb") == "solution.ipynb")
    }

    @Test func manifestDependentsReturnsScriptsThatReferenceDependency() throws {
        let manifest = try makeWorkerManifestJSON(
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
                ),
            ],
            includeMakefile: false
        )

        #expect(
            manifestDependents(manifestJSON: manifest, filename: "01_public.py") == ["02_release.py", "03_secret.py"])
        #expect(manifestDependents(manifestJSON: manifest, filename: "missing.py").isEmpty)
    }

    @Test func updateManifestAddingScriptPreservesMetadataAndAppendsEntry() throws {
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

        let updated = try #require(
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
        #expect(props.gradingMode == .browser)
        #expect(props.starterNotebook == "starter.ipynb")
        #expect(props.makefile != nil)
        #expect(props.testSuites.map(\.script) == ["01_public.py", "02_release.py"])
        #expect(props.testSuites.last?.dependsOn == ["01_public.py"])
        #expect(props.testSuites.last?.points == 2)
        #expect(props.testSuites.last?.name == "Release tests")
    }

    @Test func updateManifestRemovingScriptClearsDependencyReferences() throws {
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
                ),
            ],
            includeMakefile: false
        )

        let updated = try #require(
            updateManifestRemovingScript(manifestJSON: original, filename: "01_public.py")
        )

        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        #expect(props.testSuites.map(\.script) == ["02_release.py"])
        #expect(props.testSuites.first?.dependsOn.isEmpty ?? true)
    }

    @Test func detectRequirementSuggestionsIgnoresSolutionNotebookImports() throws {
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("detect-requirements-\(UUID().uuidString).zip")
            .path
        try ahMakeZip(
            at: zipPath,
            entries: [
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
            assignmentNotebookData: try ahNotebookData(source: "import pandas\n"),
            solutionNotebookData: try ahNotebookData(source: "import scipy\nimport matplotlib\n"),
            setup: setup
        )

        #expect(suggestions.languages == ["python"])
        #expect(suggestions.capabilities == ["pandas", "shell-bash"])
    }

    @Test func makeWorkerManifestJSONTopologicallySortsSuitesAndOmitsDefaults() throws {
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
                ),
            ],
            includeMakefile: true,
            gradingMode: "worker",
            starterNotebook: nil
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
        )
        let suites = try #require(object["testSuites"] as? [[String: Any]])

        #expect(suites.map { $0["script"] as? String } == ["01_public.py", "02_release.py", "03_secret.py"])
        #expect(object["starterNotebook"] == nil)
        #expect(object["makefile"] != nil)
        #expect(suites[0]["points"] == nil, "Default weight should be omitted")
        #expect(suites[0]["dependsOn"] == nil, "Empty dependencies should be omitted")
        #expect(suites[1]["points"] as? Int == 4)
        #expect(suites[1]["name"] as? String == "Release tests")
    }

    // PR4: a raw script's instructor hint persists onto its `TestSuiteEntry`
    // (emitted only when non-empty) and round-trips through the manifest, so
    // the PR2 display-time join surfaces it on failure.
    @Test func makeWorkerManifestJSONEmitsRawScriptHintAndRoundTrips() throws {
        let manifest = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "publictest_a.py", tier: "public", order: 1,
                    dependsOn: [], points: 1, displayName: nil, hint: "read the docstring"),
                ConfiguredSuiteEntry(
                    script: "publictest_b.py", tier: "public", order: 2,
                    dependsOn: [], points: 1, displayName: nil, hint: nil),
            ],
            includeMakefile: false
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any])
        let suites = try #require(object["testSuites"] as? [[String: Any]])
        let byScript = Dictionary(uniqueKeysWithValues: suites.map { ($0["script"] as? String ?? "", $0) })
        #expect(byScript["publictest_a.py"]?["hint"] as? String == "read the docstring")
        #expect(byScript["publictest_b.py"]?["hint"] == nil, "Absent hint must be omitted from the entry")

        let props = try JSONDecoder().decode(TestProperties.self, from: Data(manifest.utf8))
        let entryByScript = Dictionary(uniqueKeysWithValues: props.testSuites.map { ($0.script, $0) })
        #expect(entryByScript["publictest_a.py"]?.hint == "read the docstring")
        #expect(entryByScript["publictest_b.py"]?.hint == nil)
    }

    // PR4: `GET /suite` (buildSuitePayload) reads a raw script's hint back off
    // the manifest so the editor round-trips it.
    @Test func buildSuitePayloadPopulatesScriptHintFromManifest() throws {
        let manifest = """
            {
              "schemaVersion": 1,
              "testSuites": [
                { "tier": "public", "script": "publictest_a.py", "hint": "mind the boundary" },
                { "tier": "public", "script": "publictest_b.py" }
              ]
            }
            """
        let payload = buildSuitePayload(fromManifest: manifest)
        #expect(payload.items.count == 2)
        #expect(payload.items[0].script?.hint == "mind the boundary")
        #expect(payload.items[1].script?.hint == nil)
    }

    @Test func buildSuiteEntriesUsesExplicitSuiteConfigOrderingAndMetadata() throws {
        let suiteFiles = [
            ahMakeFile(named: "01_public.py", contents: "print('public')"),
            ahMakeFile(named: "notes.txt", contents: "support"),
            ahMakeFile(named: "02_secret.py", contents: "print('secret')"),
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
                2: "02_secret.py",
            ],
            suiteConfigJSON: configJSON
        )

        #expect(entries.map(\.script) == ["01_public.py", "02_secret.py"])
        #expect(entries[1].tier == "secret")
        #expect(entries[1].dependsOn == ["01_public.py"])
        #expect(entries[1].points == 3)
        #expect(entries[1].displayName == "Secret")
    }

    @Test func buildSuiteEntriesFallsBackToLikelyTestFilesAndInferredOrder() throws {
        let suiteFiles = [
            ahMakeFile(named: "20_hidden.py", contents: "print('b')"),
            ahMakeFile(named: "readme.txt", contents: "ignore"),
            ahMakeFile(named: "01_public.sh", contents: "echo test"),
        ]

        let entries = try buildSuiteEntries(
            suiteFiles: suiteFiles,
            storedNameByIndex: [
                0: "20_hidden.py",
                1: "readme.txt",
                2: "01_public.sh",
            ],
            suiteConfigJSON: nil
        )

        #expect(entries.map(\.script) == ["01_public.sh", "20_hidden.py"])
        #expect(entries.allSatisfy { $0.tier == "public" })
    }

    @Test func buildSuiteEntriesFallsBackToExtensionlessShebangScripts() throws {
        let suiteFiles = [
            ahMakeFile(named: "01_shell", contents: "#!/bin/sh\necho ok\n"),
            ahMakeFile(named: "02_bash", contents: "#!/usr/bin/env bash\necho ok\n"),
            ahMakeFile(named: "03_notes", contents: "echo support but no shebang\n"),
            ahMakeFile(named: "04_python.py", contents: "print('ok')\n"),
            ahMakeFile(named: "BMI Boundary Cases", contents: "#!/usr/bin/env python3\nprint('ok')\n"),
        ]

        let entries = try buildSuiteEntries(
            suiteFiles: suiteFiles,
            storedNameByIndex: [
                0: "01_shell",
                1: "02_bash",
                2: "03_notes",
                3: "04_python.py",
                4: "BMI Boundary Cases",
            ],
            suiteConfigJSON: nil
        )

        #expect(entries.map(\.script) == ["01_shell", "02_bash", "04_python.py", "BMI Boundary Cases"])
        #expect(entries.allSatisfy { $0.tier == "public" })
    }

    @Test func buildSuiteEntriesTreatsAnyNonSupportTierAsATestWhenIsTestIsMissing() throws {
        let suiteFiles = [
            ahMakeFile(named: "assignment.ipynb", contents: "{}"),
            ahMakeFile(named: "test_q1.py", contents: "print('q1')"),
            ahMakeFile(named: "notes.txt", contents: "support"),
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
                2: "notes.txt",
            ],
            suiteConfigJSON: configJSON
        )

        #expect(entries.map(\.script) == ["test_q1.py"])
        #expect(entries.first?.tier == "release")
        #expect(entries.first?.points == 2)
    }

    @Test func createRunnerSetupZipDeduplicatesStoredNamesAndDetectsMakefile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        let suiteFiles = [
            ahMakeFile(named: "tests.py", contents: "print('one')"),
            ahMakeFile(named: "nested/tests.py", contents: "print('two')"),
            ahMakeFile(named: "Makefile", contents: "all:\n\t@echo hi\n"),
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

        #expect(package.hasMakefile)
        #expect(package.testSuites.map(\.script) == ["tests.py", "tests-2.py"])
        #expect(package.testSuites.map(\.tier) == ["public", "secret"])

        let zipEntries = Set(listZipEntries(zipPath: zipPath))
        #expect(zipEntries.contains("tests.py"))
        #expect(zipEntries.contains("tests-2.py"))
        #expect(zipEntries.contains("Makefile"))
    }

    @Test func extractSupportFilesToSharedDirectoryRefreshesAndFiltersReservedEntries() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        try ahMakeZip(
            at: zipPath,
            entries: [
                ("assignment.ipynb", "{}"),
                ("solution.ipynb", "{}"),
                ("tests.py", "print('test')"),
                ("data/sample.csv", "a,b\n1,2\n"),
                ("notes.txt", "hello"),
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
        #expect(extracted.contains("data/sample.csv"))
        #expect(extracted.contains("notes.txt"))
        #expect(extracted.contains("tests.py") == false)
        #expect(extracted.contains("assignment.ipynb") == false)
        #expect(extracted.contains("solution.ipynb") == false)
        #expect(extracted.contains("stale.txt") == false)
    }

    @Test func removeMaterializedNotebookFilesDeletesLegacyNotebookArtifactsForSetup() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("materialized-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let publicDirectory = tempRoot.appendingPathComponent("public").path + "/"
        let roots = [
            "files/",
            "jupyterlite/files/",
            "jupyterlite/lab/files/",
            "jupyterlite/notebooks/files/",
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
                #expect(
                    FileManager.default.fileExists(atPath: publicDirectory + root + "setup_123-work.ipynb") == false)
                #expect(
                    FileManager.default.fileExists(atPath: publicDirectory + root + "other-work.ipynb")
                )
                #expect(
                    FileManager.default.fileExists(atPath: publicDirectory + root + "setup_123.txt")
                )
            }
        }
    }

}
