// Tests/APITests/ManifestMutationTests.swift
//
// `mutateManifest` is the one writer of a stored manifest: it decodes the
// setup's manifest, runs a typed edit, and stores the stable encoding.  A
// field edit must keep every other field — `languageDeclared`,
// `minimumRunnerVersion` and `activity` were each lost once by a writer that
// rebuilt the manifest from a list of fields it had to remember.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ManifestMutationTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp()
    }

    private static let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":["w.py"],\
        "testSuites":[{"tier":"public","script":"a.py","points":2,"sectionID":"s1"}],\
        "timeLimitSeconds":10,"language":"r","languageDeclared":true,\
        "minimumRunnerVersion":"0.5.1","githubSubmission":true,\
        "sections":[{"id":"s1","name":"Part 1"}],\
        "datasets":[{"file":"d.csv","kind":"rowSample","sampleSize":3}],\
        "graderOnlyFiles":["answers.R"],\
        "activity":{"kind":"bestMetric","leaderboardVisibility":"visible"}}
        """

    private func storedSetup(manifest: String, on app: Application) async throws -> APITestSetup {
        let course = try await makeTestCourse(on: app, code: "MM", name: "Manifest mutation")
        let setup = APITestSetup(
            id: "setup_mutation", manifest: manifest, zipPath: "/nonexistent/setup.zip",
            courseID: try course.requireID())
        try await setup.save(on: app.db)
        return setup
    }

    @Test func aFieldEditKeepsEveryOtherField() async throws {
        try await withApp(app) { app in
            let setup = try await storedSetup(manifest: Self.manifest, on: app)
            let before = try #require(setup.decodedManifest())

            try await mutateManifest(setup: setup, on: app.db) { props in
                props.timeLimitSeconds = 45
            }

            var expected = before
            expected.timeLimitSeconds = 45
            #expect(setup.decodedManifest() == expected)
            let reloaded = try #require(try await APITestSetup.find("setup_mutation", on: app.db))
            #expect(reloaded.manifest == setup.manifest, "the edit is saved")
        }
    }

    @Test func theStoredBytesAreTheStableEncoding() async throws {
        try await withApp(app) { app in
            let setup = try await storedSetup(manifest: Self.manifest, on: app)
            try await mutateManifest(setup: setup, on: app.db) { _ in }
            let once = setup.manifest
            #expect(once == (try encodeManifest(try #require(setup.decodedManifest()))))

            // A no-op edit rewrites the same bytes, so nothing keyed on them
            // (a version snapshot, the runner's setup cache) sees a change.
            try await mutateManifest(setup: setup, on: app.db) { _ in }
            #expect(setup.manifest == once)
        }
    }

    @Test func aManifestThatDoesNotDecodeIsRefused() async throws {
        try await withApp(app) { app in
            let setup = try await storedSetup(manifest: "not a manifest", on: app)
            await #expect(throws: WebAssignmentError.self) {
                try await mutateManifest(setup: setup, on: app.db) { props in
                    props.timeLimitSeconds = 45
                }
            }
            #expect(setup.manifest == "not a manifest", "a refused edit writes nothing")
        }
    }

    @Test func declaringNoLanguageOmitsTheKeyAndRecordsTheAnswer() async throws {
        try await withApp(app) { app in
            let setup = try await storedSetup(manifest: Self.manifest, on: app)
            try await declareManifestLanguage(setup: setup, to: nil, on: app.db)
            let props = try #require(setup.decodedManifest())
            #expect(props.language == nil)
            #expect(props.languageDeclared == true)
            #expect(!setup.manifest.contains("\"language\":"))

            // An upload-only language carries both modes with it.
            try await declareManifestLanguage(setup: setup, to: .cpp, on: app.db)
            let cpp = try #require(setup.decodedManifest())
            #expect(cpp.language == .cpp)
            #expect(cpp.submissionMode == .uploadOnly)
            #expect(cpp.gradingMode == .worker)
        }
    }
}
