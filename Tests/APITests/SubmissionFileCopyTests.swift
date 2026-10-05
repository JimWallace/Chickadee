// Tests/APITests/SubmissionFileCopyTests.swift
//
// The fresh short id and the submission file copy the two copy paths share
// (#2173).

import Foundation
import Testing

@testable import APIServer

@Suite struct SubmissionFileCopyTests {
    private func temporaryDirectory() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path + "/"
    }

    @Test func freshShortIDHasThePrefixAndEightLowercaseHexCharacters() throws {
        let id = freshShortID(prefix: "sub")
        #expect(id.hasPrefix("sub_"))
        #expect(id.count == 12)
        let tail = id.dropFirst(4)
        #expect(tail.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(freshShortID(prefix: "sub") != id)
    }

    @Test func copyKeepsTheSourceExtension() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "solution.ipynb"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: source))

        let copied = try copySubmissionFile(from: source, into: dir)

        #expect(copied.id.hasPrefix("sub_"))
        #expect(copied.path == dir + copied.id + ".ipynb")
        #expect(try Data(contentsOf: URL(fileURLWithPath: copied.path)) == Data("{}".utf8))
    }

    @Test func copyWithoutAnExtensionUsesBin() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "blob"
        try Data([0x01]).write(to: URL(fileURLWithPath: source))

        let copied = try copySubmissionFile(from: source, into: dir)

        #expect(copied.path == dir + copied.id + ".bin")
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    @Test func copyOfAMissingSourceThrows() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(throws: (any Error).self) {
            _ = try copySubmissionFile(from: dir + "missing.zip", into: dir)
        }
    }
}
