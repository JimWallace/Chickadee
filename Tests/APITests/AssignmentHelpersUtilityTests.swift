// Tests/APITests/AssignmentHelpersUtilityTests.swift
//
// Split from AssignmentHelpersTests.swift.  See AssignmentHelpersTestCase.swift
// for shared helpers (makeFile, makeZip, notebookData).

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

final class AssignmentHelpersUtilityTests {

    @Test func gradePercentFromCollectionJSONPrefersWeightedPointsAndFallsBackToCounts() {
        #expect(
            gradePercentFromCollectionJSON(
                #"{"earnedPoints":7,"totalPoints":8,"passCount":1,"totalTests":4}"#
            ) == 88)

        // Fractional earnedPoints (partial credit) rounds correctly: 2.75/4 = 68.75% → 69.
        #expect(
            gradePercentFromCollectionJSON(
                #"{"earnedPoints":2.75,"totalPoints":4,"passCount":3,"totalTests":4}"#
            ) == 69)
        #expect(gradePointsFromCollectionJSON(#"{"earnedPoints":2.75,"totalPoints":4}"#) == 2.75)

        #expect(
            gradePercentFromCollectionJSON(
                #"{"passCount":3,"totalTests":4}"#
            ) == 75)

        #expect(gradePercentFromCollectionJSON(#"{"passCount":0,"totalTests":0}"#) == nil)
        #expect(gradePercentFromCollectionJSON("not-json") == nil)
    }

    @Test func formatPointsTrimsTrailingZeros() {
        #expect(formatPoints(3) == "3")
        #expect(formatPoints(2.0) == "2")
        #expect(formatPoints(2.5) == "2.5")
        #expect(formatPoints(2.75) == "2.75")
        #expect(formatPoints(0) == "0")
    }

    @Test func csvEscapedQuotesOnlyWhenNeeded() {
        #expect(csvEscaped("plain") == "plain")
        #expect(csvEscaped("last, first") == "\"last, first\"")
        #expect(csvEscaped("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    @Test func inferNameFromStudentIDParsesCommaSeparatedNames() {
        #expect(inferNameFromStudentID("Doe, Jane").surname == "Doe")
        #expect(inferNameFromStudentID("Doe, Jane").givenNames == "Jane")
        #expect(inferNameFromStudentID("  ").surname == "—")
        #expect(inferNameFromStudentID("jdoe123").givenNames == "—")
    }

    @Test func defaultNotebookDataEmbedsAssignmentTitle() throws {
        let data = defaultNotebookData(title: "Lab \"1\"")
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#"# Lab \"1\""#))
        #expect(json.contains(#""nbformat": 4"#))
    }

    @Test func contentTypeMapsKnownTextAndNotebookTypes() {
        #expect(contentType(for: "assignment.ipynb") == .json)
        #expect(contentType(for: "notes.md") == .plainText)
        #expect(contentType(for: "archive.bin").serialize() == "application/octet-stream")
    }

    @Test func urlEncodeEscapesSpacesAndReservedCharacters() {
        #expect(urlEncode("hello world.py") == "hello%20world.py")
        #expect(urlEncode("data/results?.csv") == "data%2Fresults%3F.csv")
    }

    @Test func parseDueDateAndLocalInputStringHandleSupportedFormats() {
        let isoDate = parseDueDate("2026-03-26T14:30:00Z")
        #expect(isoDate != nil)

        let localDate = parseDueDate("2026-03-26T14:30")
        #expect(dueAtLocalInputString(localDate) == "2026-03-26T14:30")

        #expect(parseDueDate("") == nil)
        #expect(parseDueDate("not-a-date") == nil)
        #expect(dueAtLocalInputString(nil).isEmpty)
    }

    @Test func deadlineOverrideHelpersRespectPastAndFutureDueDates() {
        let past = Date().addingTimeInterval(-60)
        let future = Date().addingTimeInterval(60)

        #expect(deadlineOverrideValueForInstructorOpen(dueAt: past))
        #expect(deadlineOverrideValueForInstructorOpen(dueAt: future) == false)
        #expect(deadlineOverrideValueForInstructorOpen(dueAt: nil) == false)

        #expect(normalizedDeadlineOverrideAfterDueDateChange(dueAt: future, existingOverride: true) == false)
        #expect(normalizedDeadlineOverrideAfterDueDateChange(dueAt: nil, existingOverride: true) == false)
        #expect(normalizedDeadlineOverrideAfterDueDateChange(dueAt: past, existingOverride: true))
        #expect(normalizedDeadlineOverrideAfterDueDateChange(dueAt: past, existingOverride: false) == false)
    }

    @Test func currentSetupFilesUsesManifestOrderingAndSolutionFallbacks() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-setup-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        let notebookPath = tempRoot.appendingPathComponent("starter.ipynb").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: notebookPath))
        try ahMakeZip(
            at: zipPath,
            entries: [
                ("assignment.ipynb", "{}"),
                ("02_release.py", "print('release')"),
                ("notes.txt", "notes"),
                ("01_public.py", "print('public')"),
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

        let result = currentSetupFiles(
            for: setup,
            assignmentID: "asg123",
            solutionFilename: "BMI Boundary Cases.ipynb"
        )

        #expect(result.assignmentFile.name == "starter.ipynb")
        #expect(result.assignmentFile.url == "/instructor/asg123/files/notebook")
        #expect(result.solutionFile?.name == "BMI Boundary Cases.ipynb")
        #expect(result.solutionFile?.url == "/instructor/asg123/files/solution")
        #expect(result.existingSuiteRows.map(\.name) == ["01_public.py", "02_release.py", "notes.txt"])
        #expect(result.existingSuiteRows[0].displayName == "Public test")
        #expect(result.existingSuiteRows[1].dependsOn == ["01_public.py"])
        #expect(result.existingSuiteRows[1].points == 3)
        #expect(result.existingSuiteRows[2].tier == "support")
    }

    @Test func normalizeTierAndInferredOrderHandleFallbackCases() {
        #expect(normalizeTier(nil) == "public")
        #expect(normalizeTier("VISIBLE") == "public")
        #expect(normalizeTier("support") == "support")
        #expect(normalizeTier("secret") == "secret")
        #expect(normalizeTier("release") == "release")
        #expect(normalizeTier("mystery") == "public")
        #expect(normalizeTier("public", isTest: false) == "support")
        #expect(normalizeTier(nil, isTest: false) == "support")

        #expect(inferredOrder(from: "12_release.py") == 12)
        #expect(inferredOrder(from: "007_secret.py") == 7)
        #expect(inferredOrder(from: "notes.txt") == nil)
    }

    @Test func createRunnerSetupZipAllowsConfigsWithoutSelectedTests() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-setup-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path
        let suiteFiles = [
            ahMakeFile(named: "10_hidden.py", contents: "print('hidden')")
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

        #expect(setupZip.testSuites.isEmpty)
        #expect(FileManager.default.fileExists(atPath: zipPath))
    }

    @Test func createRunnerSetupZipReplacesExistingArchiveInsteadOfMergingRemovedFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-setup-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("setup.zip").path

        _ = try createRunnerSetupZip(
            suiteFiles: [
                ahMakeFile(named: "keep.py", contents: "print('keep')"),
                ahMakeFile(named: "remove.py", contents: "print('remove')"),
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
                ahMakeFile(named: "keep.py", contents: "print('keep-updated')")
            ],
            suiteConfigJSON: """
                [
                  {"index":0,"isTest":true,"tier":"public","points":1}
                ]
                """,
            zipPath: zipPath
        )

        let entries = Set(listZipEntries(zipPath: zipPath))
        #expect(entries == ["keep.py"])
        #expect(extractZipEntry(zipPath: zipPath, entryName: "remove.py") == nil)
        let keepData = try #require(extractZipEntry(zipPath: zipPath, entryName: "keep.py"))
        #expect(String(data: keepData, encoding: .utf8) == "print('keep-updated')")
    }

    // MARK: - mergeExistingFilesIntoSuiteFiles

    @Test func mergeExistingFilesAddsNamedDraftFilesAndRewritesRowsWithIndices() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-existing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let zipPath = tempRoot.appendingPathComponent("draft.zip").path
        try ahMakeZip(
            at: zipPath,
            entries: [
                ("test_existing.py", "print('existing')"),
                ("helper.txt", "support data"),
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
        let uploadedFile = ahMakeFile(named: "test_generated.py", contents: "print('generated')")

        let (merged, updatedJSON) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: [uploadedFile],
            suiteConfigJSON: configJSON,
            draftZipPath: zipPath
        )

        // Both files should now be in the merged list.
        #expect(merged.count == 2)
        #expect(merged.contains(where: { $0.filename == "test_generated.py" }))
        #expect(merged.contains(where: { $0.filename == "test_existing.py" }))

        // Updated JSON must use numeric 'index' for all rows so SuiteConfigRow decodes cleanly.
        let updatedData = try #require(updatedJSON?.data(using: .utf8))
        let rows = try #require(JSONSerialization.jsonObject(with: updatedData) as? [[String: Any]])
        #expect(rows.count == 2)
        for row in rows {
            #expect(row["index"] != nil, "Every row must have a numeric index after merging")
            #expect(row["name"] == nil, "'name' key should be removed after converting to index-based row")
        }
    }

    @Test func mergeExistingFilesPassesThroughPureUploadConfig() throws {
        // When no 'existing' rows are present the file list and row count should be unchanged.
        let configJSON = """
            [{"source":"upload","index":0,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1}]
            """
        let file = ahMakeFile(named: "test.py", contents: "pass")

        let (merged, updatedJSON) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: [file],
            suiteConfigJSON: configJSON,
            draftZipPath: nil
        )

        #expect(merged.count == 1)
        // Verify the row is unchanged: still one index-based row with the correct fields.
        let data = try #require(updatedJSON?.data(using: .utf8))
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["index"] as? Int == 0)
        #expect(rows[0]["name"] == nil)
    }

    @Test func detectFunctionsRoundTripIncludesBothExistingAndGeneratedTests() throws {
        // Full integration of the detect-functions save path: an assignment draft has an existing
        // test file; the instructor generates an additional test via "Detect Functions"; on save the
        // manifest must include BOTH the existing test and the newly generated one.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("detect-functions-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let draftZipPath = tempRoot.appendingPathComponent("draft.zip").path
        try ahMakeZip(
            at: draftZipPath,
            entries: [
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
        let generatedFile = ahMakeFile(named: "test_generated.py", contents: "print('generated test')")

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
        #expect(testScripts.contains("test_existing.py"), "Existing draft test must survive the save")
        #expect(testScripts.contains("test_generated.py"), "Generated test must be included in manifest")
        #expect(package.testSuites.count == 2)
    }

}
