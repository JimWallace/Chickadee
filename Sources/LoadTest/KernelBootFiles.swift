// LoadTest/KernelBootFiles.swift
//
// The kernel boot list the notebook page carries in `data-kernel-assets`
// (`KernelAssetList` on the server). The lecture run fetches exactly these
// URLs, so its join costs the server what a real kernel boot costs.

import Foundation

struct KernelBootFiles: Sendable, Decodable, Equatable {
    /// The vendored environment ("chickadee-python").
    let env: String
    /// The URL prefix of every file below.
    let base: String
    /// File paths relative to `base`.
    let files: [String]
    /// The sum of the files' sizes on disk.
    let bytes: Int

    /// Decodes the attribute's JSON. Nil when the page lists no kernel: the
    /// assignment declares none, or the server has no vendored bytes.
    static func decode(_ json: String) -> KernelBootFiles? {
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(KernelBootFiles.self, from: Data(json.utf8))
    }

    /// Each file's server path, `base` and the file joined by one slash.
    var paths: [String] {
        var prefix = base
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.hasPrefix("/") { prefix = "/" + prefix }
        return files.map { file in
            var name = Substring(file)
            while name.hasPrefix("/") { name = name.dropFirst() }
            return prefix + "/" + name
        }
    }
}
