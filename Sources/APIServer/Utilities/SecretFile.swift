// APIServer/Utilities/SecretFile.swift
//
// The files that hold a secret (`.worker-secret`, `.mcp-signing-key`,
// `.lti-tool-key`, `.github-app-secrets`) are created with mode 0600 in ONE
// call, so the secret is never readable by others, not even between the write
// and a later permission change. Four writers used to do this four ways, and
// three of them wrote first and set the mode second (#1649).

import Foundation

enum SecretFileError: Error, Equatable {
    /// The file system refused to create the file.
    case notWritten(path: String)
}

enum SecretFile {
    /// Writes `data` to `path` with mode 0600, replacing any file there.
    static func write(_ data: Data, toPath path: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        guard fileManager.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw SecretFileError.notWritten(path: path) }
    }

    /// Returns the text at `path`. When the file is absent or blank, writes
    /// the text `generate` produces there with mode 0600 and returns it.
    static func loadOrCreateText(path: String, generate: () throws -> String) throws -> String {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
            !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return existing
        }
        let created = try generate()
        try write(Data(created.utf8), toPath: path)
        return created
    }
}
