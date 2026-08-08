// Tests/APITests/BackfillDeclaredLanguageTests.swift
//
// The one-time backfill that gives every existing assignment a DECLARED
// language, which is what lets the rest of the system stop guessing: it runs
// today's resolution, writes the answer down, records "no language" truthfully
// for a shell-script suite, never overwrites a real answer, and preserves
// manifest fields it does not know about.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct BackfillDeclaredLanguageTests {

    private func manifest(_ setup: APITestSetup) throws -> TestProperties {
        try #require(setup.decodedManifest())
    }

    private func rawManifest(_ setup: APITestSetup) throws -> [String: Any] {
        try #require(
            (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8)))
                as? [String: Any])
    }

    @Test func aGradedScriptsLanguageIsRecorded() async throws {
        try await withWebRoutesApp { app in
            try await wrInsertSetup(
                id: "bf_r",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_a.R"}],"timeLimitSeconds":10}
                    """,
                on: app)

            try await BackfillDeclaredLanguage().prepare(on: app.db)

            let reloaded = try #require(try await APITestSetup.find("bf_r", on: app.db))
            let props = try manifest(reloaded)
            #expect(props.language == .r)
            #expect(props.languageDeclared == true)
        }
    }

    /// Python is recorded like any other language now. Before resolution became
    /// Optional it could not be: it was reached only by falling through, so
    /// there was no way to tell a Python assignment from an unidentified one and
    /// nothing safe to write down.
    @Test func aPythonSuiteIsRecordedAsPython() async throws {
        try await withWebRoutesApp { app in
            try await wrInsertSetup(
                id: "bf_py",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_a.py"}],"timeLimitSeconds":10}
                    """,
                on: app)

            try await BackfillDeclaredLanguage().prepare(on: app.db)

            let props = try manifest(
                try #require(try await APITestSetup.find("bf_py", on: app.db)))
            #expect(props.language == .python)
            #expect(props.languageDeclared == true)
        }
    }

    /// The case the whole design turns on. A `.sh`-only suite genuinely has no
    /// language, and saying so is what makes nil meaningful: after this runs,
    /// nil `language` WITH the flag means "declared none", not "we could not
    /// tell", so a worker can refuse the latter without breaking the former.
    @Test func aShellOnlySuiteIsDeclaredToHaveNoLanguage() async throws {
        try await withWebRoutesApp { app in
            try await wrInsertSetup(
                id: "bf_sh",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}
                    """,
                on: app)

            try await BackfillDeclaredLanguage().prepare(on: app.db)

            let reloaded = try #require(try await APITestSetup.find("bf_sh", on: app.db))
            let props = try manifest(reloaded)
            #expect(props.language == nil)
            #expect(props.languageDeclared == true)
            // Absent, not `null`: the field means "no language", and the flag
            // beside it is what says that was a decision.
            #expect(try rawManifest(reloaded)["language"] == nil)
        }
    }

    @Test func anAlreadyDeclaredManifestIsLeftAlone() async throws {
        try await withWebRoutesApp { app in
            // Declares Lua while the suite says R — an author's explicit answer
            // disagreeing with what derivation would say. The backfill must not
            // "correct" it.
            try await wrInsertSetup(
                id: "bf_declared",
                manifest: """
                    {"schemaVersion":1,"language":"lua","languageDeclared":true,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_a.R"}],"timeLimitSeconds":10}
                    """,
                on: app)

            try await BackfillDeclaredLanguage().prepare(on: app.db)

            let props = try manifest(
                try #require(try await APITestSetup.find("bf_declared", on: app.db)))
            #expect(props.language == .lua)
        }
    }

    /// Running twice must be a no-op the second time, so a re-applied migration
    /// cannot overwrite a choice an author made in between.
    @Test func theBackfillIsIdempotent() async throws {
        try await withWebRoutesApp { app in
            try await wrInsertSetup(
                id: "bf_twice",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}
                    """,
                on: app)

            try await BackfillDeclaredLanguage().prepare(on: app.db)
            let afterFirst = try #require(try await APITestSetup.find("bf_twice", on: app.db))
                .manifest
            try await BackfillDeclaredLanguage().prepare(on: app.db)
            let afterSecond = try #require(try await APITestSetup.find("bf_twice", on: app.db))
                .manifest

            #expect(afterFirst == afterSecond)
        }
    }

    /// The manifest is rewritten as raw JSON rather than round-tripped through
    /// `TestProperties`, so a field written by a NEWER build survives. A
    /// round-trip would drop it, which on a rollback would mean this migration
    /// silently ate content.
    @Test func unknownManifestFieldsSurvive() async throws {
        try await withWebRoutesApp { app in
            try await wrInsertSetup(
                id: "bf_unknown",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_a.lua"}],"timeLimitSeconds":10,"somethingNewerWrote":{"keep":"me"}}
                    """,
                on: app)

            try await BackfillDeclaredLanguage().prepare(on: app.db)

            let reloaded = try #require(try await APITestSetup.find("bf_unknown", on: app.db))
            let raw = try rawManifest(reloaded)
            #expect(raw["languageDeclared"] as? Bool == true)
            #expect(raw["language"] as? String == "lua")
            let preserved = raw["somethingNewerWrote"] as? [String: Any]
            #expect(preserved?["keep"] as? String == "me")
        }
    }
}
