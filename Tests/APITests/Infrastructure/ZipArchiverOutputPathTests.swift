// Tests/APITests/Infrastructure/ZipArchiverOutputPathTests.swift
//
// `createZipArchive` refuses an output path that already exists. `zip -r`
// adds to an existing archive instead of replacing it, so a reused path
// would merge two archives without an error (#2767).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite(.serialized, .requiresZipTools)
final class ZipArchiverOutputPathTests {

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zip-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeSource(_ name: String, file: String) throws -> URL {
        let dir = tmpDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent(file))
        return dir
    }

    @Test func refusesAnOutputPathThatExistsAndLeavesItUnchanged() async throws {
        let first = try makeSource("first", file: "first.txt")
        let second = try makeSource("second", file: "second.txt")
        let zipPath = tmpDir.appendingPathComponent("out.zip").path
        try await createZipArchive(sourceDir: first, outputPath: zipPath)
        let before = try Data(contentsOf: URL(fileURLWithPath: zipPath))

        await #expect(throws: ZipArchiverError.self) {
            try await createZipArchive(sourceDir: second, outputPath: zipPath)
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: zipPath)) == before)
        #expect(try await listZipContents(zipPath: zipPath) == ["first.txt"])
    }

    @Test func outputAlreadyExistsNamesThePath() {
        let error = ZipArchiverError.outputAlreadyExists("/tmp/a.zip")
        #expect(error.description == "Zip output path already exists: /tmp/a.zip")
    }
}
