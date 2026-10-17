// A setup zip is rewritten by staging a new zip and moving it into place
// (#2491).
//
// The rewrite helpers used to delete the live zip and then repack in place, so
// a failed `zip` left the setup with no zip. They also skipped an entry that
// failed to extract, so a file could vanish from the setup with no error.
//
// Extraction also failed for any entry whose name holds `[`, because `unzip`
// reads a member name as a pattern; such a file was dropped by the next edit.
// Names are now escaped. To get a real extraction failure, the tests corrupt
// one byte of a stored entry, which `unzip -p` reports as a bad CRC.
//
// `.serialized`: these spawn zip subprocesses, which race under within-suite
// parallelism (see `AssignmentVersionCaptureTests`).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct SetupZipRewriteTests {

    private func makeZip(_ entries: [(String, String)]) async throws -> (dir: URL, zip: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zip-rewrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("setup.zip").path
        try await writeZipFixture(at: zip, entries: entries)
        return (dir, zip)
    }

    private func stagedFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".staged-") }
    }

    @Test func aRewriteReplacesTheZipAndLeavesNoStagedFile() async throws {
        let (dir, zip) = try await makeZip([("test_a.py", "a\n"), ("helper.py", "h\n")])
        defer { try? FileManager.default.removeItem(at: dir) }

        try await updateScriptInZip(zipPath: zip, filename: "test_b.py", content: "b\n")
        try await removeScriptFromZip(zipPath: zip, filename: "helper.py")

        #expect(Set(await listZipEntries(zipPath: zip)) == ["test_a.py", "test_b.py"])
        #expect(await readScriptFromZip(zipPath: zip, filename: "test_b.py") == "b\n")
        #expect(try stagedFiles(in: dir).isEmpty)
    }

    /// A name with wildcard characters is read literally, so the file survives
    /// a rewrite. The old extraction matched nothing for `data[1].csv` and the
    /// rewrite dropped the file.
    @Test func anEntryWithWildcardCharactersSurvivesARewrite() async throws {
        let (dir, zip) = try await makeZip([("test_a.py", "a\n"), ("data[1].csv", "x,y\n"), ("q?.txt", "q\n")])
        defer { try? FileManager.default.removeItem(at: dir) }

        try await updateScriptInZip(zipPath: zip, filename: "test_b.py", content: "b\n")

        #expect(await readScriptFromZip(zipPath: zip, filename: "data[1].csv") == "x,y\n")
        #expect(await readScriptFromZip(zipPath: zip, filename: "q?.txt") == "q\n")
    }

    /// An entry that cannot be extracted fails the edit, and the live zip is
    /// left exactly as it was. The old helpers dropped the entry and repacked.
    @Test func anEntryThatCannotBeExtractedFailsTheEditAndKeepsTheZip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zip-rewrite-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: source.appendingPathComponent("test_a.py"))
        try Data("CORRUPT-ME-PAYLOAD\n".utf8).write(to: source.appendingPathComponent("bad.txt"))
        let zip = dir.appendingPathComponent("setup.zip").path
        // Stored, not deflated, so the payload bytes appear in the file as is.
        let packed = try await runZipProcess(
            executablePath: "/usr/bin/zip", arguments: ["-q", "-0", "-r", zip, "."], workingDirectory: source)
        guard packed.terminationStatus == 0 else { throw IssueRecorded("zip could not build the fixture") }
        var bytes = try Data(contentsOf: URL(fileURLWithPath: zip))
        let payload = try #require(bytes.range(of: Data("CORRUPT-ME-PAYLOAD".utf8)))
        bytes[payload.lowerBound] = UInt8(ascii: "X")
        try bytes.write(to: URL(fileURLWithPath: zip))

        await #expect(throws: ScriptZipError.self) {
            try await updateScriptInZip(zipPath: zip, filename: "test_b.py", content: "b\n")
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: zip)) == bytes)
        #expect(try stagedFiles(in: dir).isEmpty)
    }
}
