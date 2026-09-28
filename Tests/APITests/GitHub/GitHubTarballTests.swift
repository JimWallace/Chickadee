// Tests/APITests/GitHub/GitHubTarballTests.swift
//
// Converting a GitHub commit tarball into a submission zip
// (docs/github-submissions.md "Converting the tarball"): the top-level
// directory is removed, only regular files are kept, long paths survive, and
// an oversized commit or a compressed bomb is refused while it is read.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(5))) struct GitHubTarballTests {
    static let longPath =
        "src/" + String(repeating: "deeply-nested-directory/", count: 5) + "a-file-with-a-long-name.py"

    private func files(
        _ gzipped: Data, maxFileBytes: Int = GitHubTarball.maxFileBytes
    ) async throws
        -> [String: String]
    {
        let tar = try await GitHubTarball.gunzip(gzipped)
        var result: [String: String] = [:]
        for entry in try GitHubTarball.files(inTar: tar, maxFileBytes: maxFileBytes) {
            let text: String = try #require(String(data: entry.data, encoding: .utf8))
            result[entry.path] = text
        }
        return result
    }

    @Test(arguments: ["pax", "gnu"])
    func removesTheTopDirectoryAndKeepsLongPaths(format: String) async throws {
        let gzipped = try await GitHubTarballFixture.make(
            files: ["main.py": "print(1)\n", "src/util.py": "x = 2\n", Self.longPath: "long\n"],
            format: format)
        let result = try await files(gzipped)
        #expect(result == ["main.py": "print(1)\n", "src/util.py": "x = 2\n", Self.longPath: "long\n"])
        #expect(Self.longPath.count > 100, "the path must need an extended header")
    }

    @Test func dropsSymbolicLinks() async throws {
        let gzipped = try await GitHubTarballFixture.make(
            files: ["main.py": "print(1)\n"], symlinks: ["passwd": "/etc/passwd", "alias.py": "main.py"])
        let result = try await files(gzipped)
        #expect(Array(result.keys) == ["main.py"])
    }

    @Test func refusesACommitLargerThanTheLimit() async throws {
        let gzipped = try await GitHubTarballFixture.make(
            files: ["a.txt": String(repeating: "a", count: 600), "b.txt": String(repeating: "b", count: 600)])
        await #expect(throws: GitHubSubmitError.tooLarge) {
            _ = try await files(gzipped, maxFileBytes: 1_000)
        }
        let within = try await files(gzipped, maxFileBytes: 1_200)
        #expect(within.count == 2)
    }

    @Test func stopsACompressedBombAtTheCap() async throws {
        let gzipped = try await GitHubTarballFixture.make(files: ["zeros.txt": String(repeating: "0", count: 200_000)])
        #expect(gzipped.count < 10_000, "the fixture must compress well to be a bomb")
        await #expect(throws: GitHubSubmitError.tooLarge) {
            _ = try await GitHubTarball.gunzip(gzipped, limit: 50_000)
        }
    }

    @Test func refusesBytesThatAreNotGzip() async throws {
        await #expect(throws: GitHubSubmitError.unreadable) {
            _ = try await GitHubTarball.gunzip(Data("not a tarball".utf8))
        }
    }

    @Test func refusesACommitWithNoFiles() async throws {
        let gzipped = try await GitHubTarballFixture.make(files: [:], symlinks: ["only-a-link": "/etc"])
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-empty-\(UUID().uuidString).zip").path
        await #expect(throws: GitHubSubmitError.empty) {
            try await GitHubTarball.writeZip(fromGzippedTar: gzipped, to: zipPath)
        }
        #expect(!FileManager.default.fileExists(atPath: zipPath))
    }

    @Test func writesAZipWithTheFilesAtItsRoot() async throws {
        let gzipped = try await GitHubTarballFixture.make(
            files: ["main.py": "print(1)\n", "src/util.py": "x = 2\n"], symlinks: ["link": "/etc/passwd"])
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: zipPath) }
        try await GitHubTarball.writeZip(fromGzippedTar: gzipped, to: zipPath)
        let entries = await listZipEntries(zipPath: zipPath)
        #expect(Set(entries) == ["main.py", "src/util.py"])
    }

    @Test(
        arguments: [
            ("top/main.py", "main.py"),
            ("top/src/a.py", "src/a.py"),
            ("top/", nil),
            ("top", nil),
            ("top/../escape.py", nil),
            ("top/./a.py", nil),
            ("/top/abs.py", nil),
        ] as [(String, String?)])
    func strippedPath(name: String, expected: String?) {
        #expect(GitHubTarball.strippedPath(name) == expected)
    }
}
