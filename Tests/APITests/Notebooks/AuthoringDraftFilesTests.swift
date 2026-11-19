import Foundation
import Testing

@testable import APIServer

/// The staff authoring draft rule on the server drive (#2925,
/// `AuthoringDraftFiles.reconcile`): a draft keeps its unpublished edits while
/// the stored notebook is unchanged, follows the stored notebook when it has no
/// edits of its own, and when both moved, keeps its edits in a dated backup
/// beside it. Nothing is lost.
@Suite final class AuthoringDraftFilesTests {
    private let root: String
    private let draftPath: String
    private let basePath: String
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-draft-\(UUID().uuidString)").path
        draftPath = root + "/files/users/u/setup_a/assignment.ipynb"
        basePath = root + "/bases/users/u/setup_a/assignment.ipynb"
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private func notebook(_ source: String) -> Data {
        Data(#"{"cells":[{"cell_type":"code","source":["\#(source)"]}],"metadata":{},"nbformat":4}"#.utf8)
    }

    private func reconcile(seed: Data) throws -> AuthoringDraftOutcome {
        try AuthoringDraftFiles.reconcile(
            draftPath: draftPath, basePath: basePath, seed: seed, now: now, same: sameNotebookContent)
    }

    private func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }

    private func write(_ data: Data, _ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func backupName(_ outcome: AuthoringDraftOutcome) -> String? {
        if case .backedUp(let fileName) = outcome { return fileName }
        return nil
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root + "/files/users/u/setup_a")
            .filter { $0.contains("unsaved draft") }
    }

    @Test func aMissingDraftIsSeeded() throws {
        #expect(try reconcile(seed: notebook("v1")) == .seeded)
        #expect(try read(draftPath) == notebook("v1"))
        #expect(try read(basePath) == notebook("v1"))
    }

    @Test func unpublishedEditsSurviveWhileTheStoredNotebookIsUnchanged() throws {
        _ = try reconcile(seed: notebook("v1"))
        try write(notebook("v1 plus my edit"), draftPath)
        #expect(try reconcile(seed: notebook("v1")) == .kept)
        #expect(try read(draftPath) == notebook("v1 plus my edit"))
        #expect(try backups().isEmpty)
    }

    @Test func anUneditedDraftFollowsAStoredChange() throws {
        _ = try reconcile(seed: notebook("v1"))
        #expect(try reconcile(seed: notebook("v2")) == .refreshed)
        #expect(try read(draftPath) == notebook("v2"))
        #expect(try read(basePath) == notebook("v2"))
        #expect(try backups().isEmpty)
    }

    @Test func editsOnBothSidesKeepTheDraftInABackup() throws {
        _ = try reconcile(seed: notebook("v1"))
        try write(notebook("v1 plus my edit"), draftPath)
        let outcome = try reconcile(seed: notebook("v2"))
        let name = try #require(Self.backupName(outcome))
        #expect(name.hasPrefix("assignment (unsaved draft "))
        #expect(name.hasSuffix(").ipynb"))
        #expect(try read(draftPath) == notebook("v2"))
        #expect(try read(root + "/files/users/u/setup_a/" + name) == notebook("v1 plus my edit"))
        #expect(try read(basePath) == notebook("v2"))
    }

    @Test func aDraftThatAlreadyMatchesTheStoredChangeIsNotRewritten() throws {
        _ = try reconcile(seed: notebook("v1"))
        try write(notebook("v2"), draftPath)
        let before = try FileManager.default.attributesOfItem(atPath: draftPath)[.modificationDate] as? Date
        #expect(try reconcile(seed: notebook("v2")) == .refreshed)
        let after = try FileManager.default.attributesOfItem(atPath: draftPath)[.modificationDate] as? Date
        #expect(before == after)
    }

    /// A draft from before #2925 has no base.
    @Test(arguments: [true, false])
    func aDraftWithNoBase(matchesSeed: Bool) throws {
        try write(matchesSeed ? notebook("v1") : notebook("edited"), draftPath)
        let outcome = try reconcile(seed: notebook("v1"))
        if matchesSeed {
            #expect(outcome == .kept)
            #expect(try backups().isEmpty)
        } else {
            #expect(try backups().count == 1)
            #expect(try read(draftPath) == notebook("v1"))
        }
        #expect(try read(basePath) == notebook("v1"))
    }

    /// JupyterLab rewrites the kernel metadata when it saves an unedited
    /// notebook, and running it adds outputs; the draft rule must not read
    /// either as an edit.
    @Test func kernelMetadataAndOutputsAreNotEdits() {
        let stored = Data(#"{"cells":[{"cell_type":"code","source":["x = 1"]}],"metadata":{},"nbformat":4}"#.utf8)
        let resaved = Data(
            #"{"cells":[{"cell_type":"code","source":["x = 1"]}],"metadata":{"kernelspec":{"name":"python","display_name":"Python (XPython)","language":"python"}},"nbformat":4}"#
                .utf8)
        let edited = Data(#"{"cells":[{"cell_type":"code","source":["x = 2"]}],"metadata":{},"nbformat":4}"#.utf8)
        let ran = Data(
            #"{"cells":[{"cell_type":"code","source":["x = 1"],"execution_count":3,"outputs":[{"output_type":"stream","name":"stdout","text":["1"]}],"metadata":{"execution":{"iopub.status.idle":"2026-11-09T00:00:00Z"}}}],"metadata":{},"nbformat":4}"#
                .utf8)
        #expect(sameDraftContent(stored, resaved))
        #expect(sameDraftContent(stored, ran))
        #expect(!sameDraftContent(stored, edited))
    }

    @Test func aSecondBackupInTheSameMinuteGetsItsOwnName() throws {
        _ = try reconcile(seed: notebook("v1"))
        try write(notebook("edit one"), draftPath)
        _ = try reconcile(seed: notebook("v2"))
        try write(notebook("edit two"), draftPath)
        _ = try reconcile(seed: notebook("v3"))
        #expect(
            try Set(backups().map { try read(root + "/files/users/u/setup_a/" + $0) })
                == [notebook("edit one"), notebook("edit two")])
    }
}
