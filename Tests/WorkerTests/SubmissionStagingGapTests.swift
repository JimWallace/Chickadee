// Tests/WorkerTests/SubmissionStagingGapTests.swift
//
// Closes mutation survivors in `Sources/Worker/SubmissionStaging.swift` on two
// properties that are load-bearing and were both unasserted.
//
// 1. THE TEST-SETUP CACHE KEY. CLAUDE.md states the contract in one line --
//    "Cache key hashes manifest + zip content, so any suite edit busts the
//    entry." Nothing checked it. The survivors here delete individual
//    `material.append` calls, and the one that deletes the manifest bytes makes
//    an edited suite hash to the SAME key as the suite it replaced: the runner
//    then grades every later submission against a cached copy of the old tests,
//    silently and with no failure anywhere.
//
// 2. THE PROTECTED WORKSPACE FILENAMES. This set is what stops a student's own
//    files from overwriting the tests they are about to be graded by (#1357).
//    A name dropped from it is a hole with no symptom until someone uses it.
//
// The cache-key tests are written as one-field-apart PAIRS rather than as
// golden digests. A golden digest pins the hash to an implementation and has to
// be rewritten whenever the material changes, which is exactly when you want
// the test to still mean something; a pair states the property -- different
// inputs, different key -- and survives the rewrite.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct SubmissionStagingGapTests {

    private static func makeJob(
        testSetupID: String = "ts_1",
        testSetupURL: String = "https://server.test/ts.zip",
        manifest: TestProperties = TestProperties()
    ) throws -> Job {
        Job(
            submissionID: "sub_1",
            testSetupID: testSetupID,
            attemptNumber: 1,
            submissionURL: try #require(URL(string: "https://server.test/sub.zip")),
            testSetupURL: try #require(URL(string: testSetupURL)),
            manifest: manifest,
            submissionFilename: "main.py",
            assignmentSeed: nil
        )
    }

    private static func manifest(withScript script: String) throws -> TestProperties {
        let jsonObject: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": [],
            "testSuites": [["tier": "public", "script": script]],
            "timeLimitSeconds": 10,
            "makefile": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try JSONDecoder().decode(TestProperties.self, from: data)
    }

    /// Survivor: `:434 RemoveSideEffects` — deleting
    /// `material.append(manifestBytes)`.
    ///
    /// This is the one with teeth. The cache is keyed so that editing a suite
    /// busts the entry; drop the manifest from the material and an edited suite
    /// keys to the same entry as the suite it replaced, so the runner keeps
    /// grading against a cached copy of the OLD tests. No error, no failed
    /// test — just every student after the edit graded on the wrong suite.
    @Test func editingTheSuiteChangesTheCacheKey() throws {
        let before = try Self.makeJob(manifest: try Self.manifest(withScript: "test_one.py"))
        let after = try Self.makeJob(manifest: try Self.manifest(withScript: "test_two.py"))

        #expect(
            testSetupCacheKey(for: before) != testSetupCacheKey(for: after),
            "a suite edit must bust the cached test setup")
    }

    /// Survivor: `:432 RemoveSideEffects` — deleting the test-setup URL from
    /// the material.
    ///
    /// Same identifier pointing at a different artifact must not reuse the
    /// cached directory.
    @Test func adifferentTestSetupURLChangesTheCacheKey() throws {
        let first = try Self.makeJob(testSetupURL: "https://server.test/ts.zip")
        let second = try Self.makeJob(testSetupURL: "https://server.test/other.zip")

        #expect(testSetupCacheKey(for: first) != testSetupCacheKey(for: second))
    }

    /// Survivor: `:431 RemoveSideEffects` — deleting the zero byte that
    /// separates the test-setup id from the URL.
    ///
    /// Without it the material is a plain concatenation, so the boundary
    /// between the two fields can move without changing a single byte. The
    /// pair below is crafted to sit exactly on that boundary —
    /// `"a" + "https://b/c"` and `"ahttps://b" + "/c"` concatenate
    /// identically — because any ordinary pair differs anyway and would let
    /// the mutant survive a green test.
    ///
    /// Compared on the digest half alone: the key's prefix carries the id
    /// verbatim, so the full keys differ here whatever the digest does, and
    /// asserting on them would pass for the wrong reason.
    @Test func theIdUrlBoundaryCannotBeMovedWithoutChangingTheDigest() throws {
        let first = try Self.makeJob(testSetupID: "a", testSetupURL: "https://b/c")
        let second = try Self.makeJob(testSetupID: "ahttps://b", testSetupURL: "/c")

        #expect(
            Self.digest(of: first) != Self.digest(of: second),
            "the id/url boundary must not be ambiguous")
    }

    /// The hash half of the key, with the `"\(testSetupID)-"` prefix removed.
    private static func digest(of job: Job) -> String {
        String(testSetupCacheKey(for: job).dropFirst(job.testSetupID.count + 1))
    }

    /// Survivor: `:78 RemoveSideEffects` — dropping
    /// `.chickadee_student_source` from the protected set.
    ///
    /// The set is what refuses a student's file that would overwrite the tests
    /// or the runtime scaffolding grading them (#1357). Asserted by naming the
    /// two dotfiles the function inserts by hand: the rest of the set is
    /// derived from the manifest and the language table, and is covered by
    /// ProtectedWorkspaceFilenameTests.
    @Test func theProtectedSetKeepsTheStudentModuleDotfiles() throws {
        let names = protectedWorkspaceFilenames(
            manifest: try Self.manifest(withScript: "test_public.py"))

        #expect(names.contains(".chickadee_student_source"))
        #expect(names.contains(".chickadee_student_module"))
        #expect(names.contains("test_public.py"))
    }
}
