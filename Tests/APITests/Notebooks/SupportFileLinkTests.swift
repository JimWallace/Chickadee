import Foundation
import Testing

@testable import APIServer

/// The working-copy link pass (`linkSupportFiles`) puts each support file of a
/// setup's shared extraction into a student's JupyterLite folder. A support
/// file in a subfolder of the setup zip (`data/patients.csv`) needs its parent
/// folder made first; before the fix the link failed and nothing was logged.
@Suite final class SupportFileLinkTests {
    private let root: String
    private let sharedDir: String
    private let studentDir: String

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-support-links-\(UUID().uuidString)")
            .path
        sharedDir = root + "/shared/setup/"
        studentDir = root + "/student"
        let fm = FileManager.default
        try fm.createDirectory(atPath: sharedDir + "data/raw", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: studentDir, withIntermediateDirectories: true)
        try Data("top".utf8).write(to: URL(fileURLWithPath: sharedDir + "helpers.py"))
        try Data("rows".utf8).write(to: URL(fileURLWithPath: sharedDir + "data/patients.csv"))
        try Data("deep".utf8).write(to: URL(fileURLWithPath: sharedDir + "data/raw/visits.csv"))
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOfFile: studentDir + "/" + relativePath, encoding: .utf8)
    }

    private func isSymlink(_ relativePath: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: studentDir + "/" + relativePath)) != nil
    }

    @Test("A support file in a subfolder is linked, with its parent folders made")
    func nestedSupportFileIsLinked() throws {
        let failures = linkSupportFiles(
            ["helpers.py", "data/patients.csv", "data/raw/visits.csv"],
            sharedDirectory: sharedDir,
            studentDirectory: studentDir)

        #expect(failures.isEmpty)
        #expect(try contents("helpers.py") == "top")
        #expect(try contents("data/patients.csv") == "rows")
        #expect(try contents("data/raw/visits.csv") == "deep")
        #expect(isSymlink("data/patients.csv"))
        #expect(isSymlink("data/raw/visits.csv"))
    }

    @Test("The pass is idempotent: a second run links nothing new and reports nothing")
    func secondPassIsANoOp() throws {
        let names = ["helpers.py", "data/patients.csv"]
        #expect(linkSupportFiles(names, sharedDirectory: sharedDir, studentDirectory: studentDir).isEmpty)
        #expect(linkSupportFiles(names, sharedDirectory: sharedDir, studentDirectory: studentDir).isEmpty)
        #expect(try contents("data/patients.csv") == "rows")
    }

    @Test("A folder entry such as data/ is skipped, not linked")
    func folderEntryIsSkipped() throws {
        let failures = linkSupportFiles(
            ["data/", "data/raw/"], sharedDirectory: sharedDir, studentDirectory: studentDir)

        #expect(failures.isEmpty)
        #expect(!isSymlink("data"))
        #expect(!isSymlink("data/raw"))
        #expect(!FileManager.default.fileExists(atPath: studentDir + "/data"))
    }

    @Test("A name not yet extracted is skipped quietly, and makes no folder")
    func missingSourceIsSkipped() {
        let failures = linkSupportFiles(
            ["later/notes.txt"], sharedDirectory: sharedDir, studentDirectory: studentDir)

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: studentDir + "/later"))
    }

    @Test("A real file already at the destination is kept, not replaced by a link")
    func existingFileIsKept() throws {
        try FileManager.default.createDirectory(atPath: studentDir + "/data", withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: studentDir + "/data/patients.csv"))

        let failures = linkSupportFiles(
            ["data/patients.csv"], sharedDirectory: sharedDir, studentDirectory: studentDir)

        #expect(failures.isEmpty)
        #expect(try contents("data/patients.csv") == "mine")
        #expect(!isSymlink("data/patients.csv"))
    }

    @Test("A link already at the destination is kept, even when its target is gone")
    func danglingLinkIsKept() throws {
        try FileManager.default.createSymbolicLink(
            atPath: studentDir + "/helpers.py", withDestinationPath: root + "/gone.py")

        let failures = linkSupportFiles(["helpers.py"], sharedDirectory: sharedDir, studentDirectory: studentDir)

        #expect(failures.isEmpty)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: studentDir + "/helpers.py") == root + "/gone.py")
    }

    @Test("A name that leaves the student folder is refused and makes no folder")
    func escapingNameIsRefused() throws {
        try Data("outside".utf8).write(to: URL(fileURLWithPath: sharedDir + "escape.csv"))

        let failures = linkSupportFiles(
            ["../outside/escape.csv", "/abs/escape.csv"], sharedDirectory: sharedDir, studentDirectory: studentDir)

        #expect(failures.map(\.name) == ["../outside/escape.csv", "/abs/escape.csv"])
        #expect(!FileManager.default.fileExists(atPath: root + "/outside"))
    }

    @Test("A link that cannot be made is reported, not swallowed")
    func blockedParentIsReported() throws {
        try Data("a file, not a folder".utf8).write(to: URL(fileURLWithPath: studentDir + "/data"))

        let failures = linkSupportFiles(
            ["data/patients.csv", "helpers.py"], sharedDirectory: sharedDir, studentDirectory: studentDir)

        #expect(failures.map(\.name) == ["data/patients.csv"])
        #expect(try contents("helpers.py") == "top")
    }
}
