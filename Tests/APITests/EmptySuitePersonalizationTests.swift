// Regression tests for the empty-suite zip-repack bug: `repackZipFromDirectory`
// shelled out to `zip -r .`, which aborts with "Nothing to do!" (exit 12) on an
// empty source directory. That raw `ScriptZipError` escaped GlobalInputsService
// (which only maps WebAssignmentError), so adding personalization to a
// brand-new assignment — whose setup zip has no test files yet — failed with an
// opaque error. The fix emits a valid empty archive instead.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct EmptySuitePersonalizationTests {

    /// Writes the canonical 22-byte empty zip (End-Of-Central-Directory only) so
    /// the test reproduces a brand-new setup's truly-empty archive without
    /// depending on the code under test.
    private func writeEmptyZipFile(at path: String) throws {
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
        try? FileManager.default.removeItem(atPath: path)
        try Data(eocd).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Unit: repack an empty directory

    @Test func repackEmptyDirectoryProducesUsableEmptyZip() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("empty-src-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let zipPath = fm.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).zip").path
        defer { try? fm.removeItem(atPath: zipPath) }

        // Previously threw ScriptZipError.zipFailed (zip "Nothing to do!").
        try repackZipFromDirectory(zipPath: zipPath, sourceDir: dir)

        #expect(fm.fileExists(atPath: zipPath))
        #expect(listZipEntries(zipPath: zipPath).isEmpty)

        // The empty archive is still usable: a later add round-trips.
        try applyScriptChangesToZip(zipPath: zipPath, writes: ["t.sh": "exit 0\n"], deletions: [])
        #expect(listZipEntries(zipPath: zipPath) == ["t.sh"])
    }

    // MARK: - Integration: global inputs on an empty suite

    @Test func globalInputsSucceedOnEmptySuite() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            let manifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
            try await makeTestSetup(on: app, id: "setup_empty", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_empty", courseID: courseID, title: "Fresh")

            // Reproduce a brand-new assignment: an empty setup zip (no test files).
            let setup = try #require(try await APITestSetup.find("setup_empty", on: app.db))
            try writeEmptyZipFile(at: setup.zipPath)

            // Before the fix this threw ScriptZipError.zipFailed on the empty
            // repack. `actingUserID: nil` skips the per-seed eval so the test
            // isolates the zip path. A literal `fortunes` list is the exact
            // shape the Lab 5 authoring flow hit.
            let result = try await GlobalInputsService.apply(
                setup: setup,
                assignment: assignment,
                actingUserID: nil,
                inputs: .init(
                    variables: [
                        FamilyVariable(name: "fortunes", value: .array([.string("a"), .string("b")]))
                    ],
                    expressions: []),
                testSetupsDirectory: app.testSetupsDirectory,
                on: app.db,
                seedDB: app.db)

            #expect(result.variables.contains { $0.name == "fortunes" })

            // The setup zip is still a valid (empty) archive afterwards.
            let reloaded = try #require(try await APITestSetup.find("setup_empty", on: app.db))
            #expect(listZipEntries(zipPath: reloaded.zipPath).isEmpty)
        }
    }
}
