// Tests/WorkerTests/Submissions/SubmissionStagingTests.swift
//
// `Sources/Worker/SubmissionStaging.swift`, in two suites: the mutation
// survivors on the test-setup cache key and the protected workspace
// filenames, and the edges no other suite reached.

import Core
import Foundation
import Testing

@testable import chickadee_runner

// MARK: - SubmissionStagingGapTests

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
// THE MISSING HALF OF THE CACHE CONTRACT. CLAUDE.md states one direction --
// "Cache key hashes manifest + zip content, so any suite edit busts the entry"
// -- and that is what the assertions below started as. The converse went
// unstated and unasserted: equal content must key IDENTICALLY, or the cache
// never hits at all.
//
// It did not. `testSetupCacheKey` hashed `ManifestCodec.encoder`, whose key
// order is not contractual, so the same job keyed two ways and every test setup
// was re-downloaded and re-extracted with nothing in the logs to say why
// (#1526). It also masked three mutants in this very file: an assertion of the
// form "these two jobs must hash differently" passes for free whenever the
// encoder disagrees with itself, which is exactly when a mutant that drops a
// field from the hashed material would otherwise be caught. Measured for :432
// as SURVIVED, KILLED, KILLED across three identical runs.
//
// `theSameJobAlwaysKeysTheSameWay` is the assertion that was missing. The other
// three are now reliable killers because it holds.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

@Suite(.timeLimit(.minutes(3))) struct SubmissionStagingGapTests {

    private static func makeJob(
        testSetupID: String = "ts_1",
        testSetupURL: String = "https://server.test/ts.zip",
        manifest: TestProperties = TestProperties(language: nil)
    ) throws -> Job {
        Job(
            submissionID: "sub_1",
            testSetupID: testSetupID,
            attemptNumber: 1,
            submissionURL: try #require(URL(string: "https://server.test/sub.zip")),
            testSetupURL: try #require(URL(string: testSetupURL)),
            manifest: manifest,
            submissionFilename: "main.py",
            assignmentSeed: nil, language: nil
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
    /// the hashed material.
    ///
    /// The same identifier pointing at a different artifact must not reuse the
    /// cached directory.
    @Test func adifferentTestSetupURLChangesTheCacheKey() throws {
        let first = try Self.makeJob(testSetupURL: "https://server.test/ts.zip")
        let second = try Self.makeJob(testSetupURL: "https://server.test/other.zip")

        #expect(testSetupCacheKey(for: first) != testSetupCacheKey(for: second))
    }

    /// The property `testSetupCacheKey` lacked, and the reason #1526 existed:
    /// the same job must always produce the same key.
    ///
    /// Repeated rather than compared once, because the failure was
    /// intermittent — the shared encoder emitted a stable order on some runs
    /// and alternating orders on others, so a single pair of calls agreed most
    /// of the time. A one-shot assertion here would have passed against the
    /// broken code roughly half the time, which is worse than not having it.
    @Test func theSameJobAlwaysKeysTheSameWay() throws {
        let job = try Self.makeJob(manifest: try Self.manifest(withScript: "test_public.py"))

        let keys = Set((0..<200).map { _ in testSetupCacheKey(for: job) })

        #expect(
            keys.count == 1,
            "one job must hash to one key; got \(keys.count) distinct: \(keys.sorted().prefix(3))")
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
            manifest: try Self.manifest(withScript: "test_public.py").runnerManifest())

        #expect(names.contains(".chickadee_student_source"))
        #expect(names.contains(".chickadee_student_module"))
        #expect(names.contains("test_public.py"))
    }
}

// MARK: - SubmissionStagingEdgeTests

// The edges of `Sources/Worker/SubmissionStaging.swift` that no other suite
// reached: a free-space probe that the OS cannot answer, a merge from a
// source that does not exist or that links outside itself, Python's last
// heuristic (a `.py` file anywhere in the upload), and the messages that
// `WorkerDaemonError` gives a person.

@Suite final class SubmissionStagingEdgeTests {

    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-staging-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func directory(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Free space

    /// A path the OS cannot answer for returns nil, so the caller skips the
    /// disk precheck instead of refusing the job.
    @Test func freeSpaceForAMissingPathIsUnknown() {
        #expect(freeSpaceMB(at: tempDir.appendingPathComponent("does-not-exist/deeper")) == nil)
    }

    @Test func freeSpaceForAnExistingPathIsKnown() throws {
        let free = try #require(freeSpaceMB(at: tempDir))
        #expect(free >= 0)
    }

    // MARK: - Merge

    /// A source that does not exist merges nothing and skips nothing.
    @Test func mergingFromAMissingSourceCopiesNothing() throws {
        let destination = try directory("dest")
        let skipped = try mergeDirectoryContents(
            from: tempDir.appendingPathComponent("no-source", isDirectory: true), into: destination)
        #expect(skipped.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// A link in the upload that points outside it never brings the outside
    /// file into the workspace; the upload's own files still merge.
    @Test func aLinkThatLeavesTheSourceIsNotFollowedIntoTheWorkspace() throws {
        let outside = try directory("outside")
        try "secret\n".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let source = try directory("source")
        try "x = 1\n".write(to: source.appendingPathComponent("solution.py"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("leak.txt"),
            withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let destination = try directory("dest")

        try mergeDirectoryContents(from: source, into: destination)

        let merged = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(merged.contains("solution.py"))
        #expect(!merged.contains("leak.txt"))
    }

    // MARK: - Normalization

    private static let shellOnlyManifest = TestProperties(
        testSuites: [TestSuiteEntry(tier: .pub, script: "test.sh")], language: nil
    ).runnerManifest()

    /// With no Python suite and an upload name that says nothing, a `.py`
    /// file anywhere in the upload claims it for Python.
    @Test func aPythonFileInAnUnnamedUploadMakesItAPythonModule() throws {
        let upload = try directory("upload-py")
        let nested = upload.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "notes\n".write(to: upload.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try "x = 1\n".write(to: nested.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)

        let normalization = submissionNormalization(
            manifest: Self.shellOnlyManifest, submissionFilename: "upload.zip", submissionDirectory: upload)

        #expect(normalization == .pythonModule)
    }

    /// The same upload without a `.py` file is claimed by nobody, so it is
    /// extracted generically.
    @Test func anUploadWithNoPythonFileIsExtractedGenerically() throws {
        let upload = try directory("upload-txt")
        try "notes\n".write(to: upload.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let normalization = submissionNormalization(
            manifest: Self.shellOnlyManifest, submissionFilename: "upload.zip", submissionDirectory: upload)

        #expect(normalization == .extractToSource(forcedLanguage: nil))
    }

    // MARK: - Error messages

    @Test func anHTTPDownloadFailureNamesTheStatusAndBody() {
        let error = WorkerDaemonError.httpDownloadFailure(statusCode: 502, body: "bad gateway")
        #expect(error.errorDescription == "HTTP 502 while downloading artifacts: bad gateway")
    }

    @Test func aMakeFailureWithoutDetailIsOnlyTheHeading() {
        #expect(WorkerDaemonError.makeFailed(target: "build", detail: nil).errorDescription == "make build failed")
        #expect(WorkerDaemonError.makeFailed(target: nil, detail: "").errorDescription == "make  failed")
    }

    @Test func aMakeFailureWithDetailPutsTheOutputUnderTheHeading() {
        let error = WorkerDaemonError.makeFailed(target: "all", detail: "main.c:3: error")
        #expect(error.errorDescription == "make all failed\nmain.c:3: error")
    }

    @Test func aMakeTimeoutNamesTheLimit() {
        let error = WorkerDaemonError.makeTimedOut(target: nil, limitSeconds: 120)
        #expect(error.errorDescription == "make  exceeded the 120s build time limit and was killed")
    }

    @Test func insufficientDiskSpaceNamesThePathAndBothSizes() {
        let error = WorkerDaemonError.insufficientDiskSpace(path: "/work", freeMB: 12, requiredMB: 512)
        #expect(
            error.errorDescription
                == "Runner workspace at /work has 12 MB free; need at least 512 MB before accepting a job")
    }

    @Test func anUnsafePersonalizedFilenameIsQuoted() {
        let error = WorkerDaemonError.unsafePersonalizedFilename("../escape.csv")
        #expect(
            error.errorDescription
                == "Personalized file name '../escape.csv' is not a bare filename; refusing to write it")
    }
}
