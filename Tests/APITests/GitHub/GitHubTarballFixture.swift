// Tests/APITests/GitHub/GitHubTarballFixture.swift
//
// Builds a real gzipped tarball shaped like GitHub's: one top-level
// directory, `{owner}-{repo}-{sha}/`, holding the repository's files. Made
// with the system `tar`, so the converter reads the format a real archiver
// writes rather than one the test invents.

import Core
import Foundation

@testable import APIServer

enum GitHubTarballFixture {
    static let topDirectory = "octo-student-lab1-0123abc"

    /// `files` maps a path inside the repository to its text; `symlinks` maps
    /// a path to its link target. `format` is a `tar --format` value.
    static func make(
        files: [String: String], symlinks: [String: String] = [:], format: String = "pax"
    ) async throws -> Data {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chickadee-tarball-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let top = root.appendingPathComponent(topDirectory)
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = top.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for (path, target) in symlinks {
            try fm.createSymbolicLink(
                atPath: top.appendingPathComponent(path).path, withDestinationPath: target)
        }
        let output = root.appendingPathComponent("repo.tar.gz").path
        try await runZipProcessExpectingSuccess(
            executablePath: "/usr/bin/tar",
            arguments: ["--format=\(format)", "-czf", output, topDirectory],
            workingDirectory: root)
        return try Data(contentsOf: URL(fileURLWithPath: output))
    }
}
