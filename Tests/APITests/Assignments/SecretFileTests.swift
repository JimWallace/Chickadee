// Tests for SecretFile: a secret file is owner read/write only from the
// moment it exists, a wider file is replaced at 0600, and loadOrCreateText
// generates only when the file is absent or blank.

import Foundation
import Testing

@testable import APIServer

@Suite final class SecretFileTests {
    let directory: URL
    var path: String { directory.appendingPathComponent(".secret").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-secret-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test func writeCreatesAnOwnerOnlyFile() throws {
        try SecretFile.write(Data("s3cret".utf8), toPath: path)
        #expect(try permissions() == 0o600)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "s3cret")
    }

    @Test func writeReplacesAWiderFileAt0600() throws {
        _ = FileManager.default.createFile(
            atPath: path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        try SecretFile.write(Data("new".utf8), toPath: path)
        #expect(try permissions() == 0o600)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new")
    }

    @Test func writeIntoAMissingDirectoryThrowsNotWritten() {
        let missing = directory.appendingPathComponent("absent/.secret").path
        #expect(throws: SecretFileError.notWritten(path: missing)) {
            try SecretFile.write(Data("x".utf8), toPath: missing)
        }
    }

    @Test func loadOrCreateTextGeneratesOnlyWhenAbsentOrBlank() throws {
        var generated = 0
        let first = try SecretFile.loadOrCreateText(path: path) {
            generated += 1
            return "generated-\(generated)"
        }
        #expect(first == "generated-1")
        #expect(try permissions() == 0o600)

        let second = try SecretFile.loadOrCreateText(path: path) {
            generated += 1
            return "generated-\(generated)"
        }
        #expect(second == "generated-1")
        #expect(generated == 1)

        try Data("  \n".utf8).write(to: URL(fileURLWithPath: path))
        let third = try SecretFile.loadOrCreateText(path: path) {
            generated += 1
            return "generated-\(generated)"
        }
        #expect(third == "generated-2")
        #expect(try permissions() == 0o600)
    }
}
