// Tests/APITests/ManifestConcurrentEditTests.swift
//
// Two staff edits on one assignment at once must both survive (#2019).
// `mutateManifest` used to decode, edit and save the whole manifest with no
// check that it had not changed in between, so the first edit was lost.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ManifestConcurrentEditTests {

    /// A saved setup with a default manifest, and its id.
    private func makeSetup(_ app: Application, id: String) async throws -> String {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let manifest = try encodeManifest(TestProperties())
        try await APITestSetup(
            id: id, manifest: manifest, zipPath: app.testSetupsDirectory + "\(id).zip",
            courseID: courseID
        ).save(on: app.db)
        return id
    }

    private func stored(_ app: Application, _ id: String) async throws -> TestProperties {
        let setup = try #require(try await APITestSetup.find(id, on: app.db))
        return try #require(setup.decodedManifest())
    }

    /// Both editors read the same manifest. The second to save must find it
    /// changed and apply its edit on top, not overwrite the first.
    @Test func twoEditsFromTheSameReadBothSurvive() async throws {
        try await withAssignmentRoutesApp { app in
            let id = try await makeSetup(app, id: "cas_both")
            let first = try #require(try await APITestSetup.find(id, on: app.db))
            let second = try #require(try await APITestSetup.find(id, on: app.db))

            try await mutateManifest(setup: second, on: app.db) { $0.timeLimitSeconds = 42 }
            try await mutateManifest(setup: first, on: app.db) { $0.requiredFiles.append("lab.py") }

            let props = try await stored(app, id)
            #expect(props.timeLimitSeconds == 42, "the first edit to save was lost")
            #expect(props.requiredFiles == ["lab.py"])
            // The late editor's model now holds what it saved.
            #expect(first.decodedManifest()?.timeLimitSeconds == 42)
        }
    }

    /// After a conditional save the model holds the manifest as saved, not as
    /// a pending change, so saving the model later for another reason does not
    /// write the manifest again over a newer edit.
    @Test func aLaterSaveOfTheModelDoesNotRewriteTheManifest() async throws {
        try await withAssignmentRoutesApp { app in
            let id = try await makeSetup(app, id: "cas_clean")
            let editor = try #require(try await APITestSetup.find(id, on: app.db))
            try await mutateManifest(setup: editor, on: app.db) { $0.timeLimitSeconds = 30 }
            #expect(!editor.hasChanges)

            let other = try #require(try await APITestSetup.find(id, on: app.db))
            try await mutateManifest(setup: other, on: app.db) { $0.requiredFiles = ["b.py"] }

            editor.notebookPath = "starter.ipynb"
            try await editor.save(on: app.db)

            let props = try await stored(app, id)
            #expect(props.requiredFiles == ["b.py"], "a plain save rewrote the manifest")
            #expect(props.timeLimitSeconds == 30)
        }
    }

    /// A conflict re-runs the edit on the manifest the other editor saved, so
    /// the edit works from current state, never from the stale read.
    @Test func aRerunEditSeesTheNewerManifest() async throws {
        try await withAssignmentRoutesApp { app in
            let id = try await makeSetup(app, id: "cas_rerun")
            let late = try #require(try await APITestSetup.find(id, on: app.db))
            let early = try #require(try await APITestSetup.find(id, on: app.db))
            try await mutateManifest(setup: early, on: app.db) { $0.requiredFiles = ["a.py"] }

            var seen: [[String]] = []
            try await mutateManifest(setup: late, on: app.db) { props in
                seen.append(props.requiredFiles)
                props.requiredFiles.append("b.py")
            }
            #expect(seen == [[], ["a.py"]], "the edit ran once on the stale read, then on the saved one")
            #expect(try await stored(app, id).requiredFiles == ["a.py", "b.py"])
        }
    }
}
