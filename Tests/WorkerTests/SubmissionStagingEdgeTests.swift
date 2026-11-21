// Tests/WorkerTests/SubmissionStagingEdgeTests.swift
//
// The edges of `Sources/Worker/SubmissionStaging.swift` that no other suite
// reached: a free-space probe that the OS cannot answer, a merge from a
// source that does not exist or that links outside itself, Python's last
// heuristic (a `.py` file anywhere in the upload), and the messages that
// `WorkerDaemonError` gives a person.

import Core
import Foundation
import Testing

@testable import chickadee_runner

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
