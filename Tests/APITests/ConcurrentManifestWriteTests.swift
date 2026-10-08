// A manifest write that did slow work between its read and its save must not
// overwrite an edit that saved in between (#2485).
//
// `mutateManifest` already writes conditionally and re-applies a lost edit.
// `applyPatternFamilies` (PUT /suite, the MCP suite tools, global inputs) and
// the script create and delete read the manifest, change the zip, and then
// saved with no condition. An achievements or dataset edit that saved in
// between was lost with no error. These tests run that interleaving: a second
// copy of the setup row saves an edit after the first copy was read.
//
// `applyPatternFamilies` refuses with a conflict, because its rendered files
// were built from the old manifest. The script create and delete apply their
// one-entry change again to the newer manifest and keep both edits.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct ConcurrentManifestWriteTests {

    /// Saves an edit through a second copy of the setup row, as a concurrent
    /// request would, and returns the manifest it saved.
    private func saveConcurrentEdit(to setup: APITestSetup, on db: any Database) async throws -> String {
        let other = try #require(try await APITestSetup.find(setup.id, on: db))
        try await mutateManifest(setup: other, on: db) { $0.timeLimitSeconds = 77 }
        return other.manifest
    }

    @Test func applyPatternFamiliesRefusesToOverwriteAConcurrentEdit() async throws {
        try await withPatternFamilyFixture { fixture in
            let concurrent = try await saveConcurrentEdit(to: fixture.setup, on: fixture.app.db)

            await #expect(throws: (any Error).self) {
                try await applyPatternFamilies(
                    to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)
            }

            let stored = try #require(try await APITestSetup.find(fixture.setup.id, on: fixture.app.db))
            #expect(stored.manifest == concurrent, "The concurrent edit was overwritten.")
        }
    }

    @Test func applyPatternFamiliesStillSavesWithoutAConcurrentEdit() async throws {
        try await withPatternFamilyFixture { fixture in
            try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            let stored = try #require(try await APITestSetup.find(fixture.setup.id, on: fixture.app.db))
            #expect(stored.decodedManifest()?.patternFamilies.count == 1)
        }
    }

    /// A script create changes the manifest by adding one entry, which can be
    /// applied again to the newer manifest. So it keeps both edits instead of
    /// refusing.
    @Test func createScriptKeepsAConcurrentEdit() async throws {
        try await withPatternFamilyFixture { fixture in
            _ = try await saveConcurrentEdit(to: fixture.setup, on: fixture.app.db)

            _ = try await createScriptInSetup(
                setup: fixture.setup,
                body: CreateScriptBody(
                    filename: "test_new.py", content: "print('x')\n", tier: "public", points: 1, isTest: true),
                kernelEnvironments: nil, on: fixture.app.db)

            let stored = try #require(try await APITestSetup.find(fixture.setup.id, on: fixture.app.db))
            let props = try #require(stored.decodedManifest())
            #expect(props.timeLimitSeconds == 77, "The concurrent edit was overwritten.")
            #expect(props.testSuites.contains { $0.script == "test_new.py" })
        }
    }

    /// The same for a script delete.
    @Test func deleteScriptKeepsAConcurrentEdit() async throws {
        try await withPatternFamilyFixture { fixture in
            _ = try await createScriptInSetup(
                setup: fixture.setup,
                body: CreateScriptBody(
                    filename: "test_old.py", content: "print('x')\n", tier: "public", points: 1, isTest: true),
                kernelEnvironments: nil, on: fixture.app.db)
            _ = try await saveConcurrentEdit(to: fixture.setup, on: fixture.app.db)

            try await deleteScriptFromSetup(setup: fixture.setup, filename: "test_old.py", on: fixture.app.db)

            let stored = try #require(try await APITestSetup.find(fixture.setup.id, on: fixture.app.db))
            let props = try #require(stored.decodedManifest())
            #expect(props.timeLimitSeconds == 77, "The concurrent edit was overwritten.")
            #expect(!props.testSuites.contains { $0.script == "test_old.py" })
        }
    }
}
