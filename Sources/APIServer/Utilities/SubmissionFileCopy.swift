// APIServer/Utilities/SubmissionFileCopy.swift
//
// Copies a submission file under a fresh submission id (#2173). The clone
// and the bundle import each spelled these five lines themselves.

import Foundation

/// Copies the file at `sourcePath` into `directory` under a fresh
/// submission id, keeping the source extension, or `.bin` when it has none.
/// Returns the new id and the destination path.
func copySubmissionFile(from sourcePath: String, into directory: String) throws -> (id: String, path: String) {
    let id = freshShortID(prefix: "sub")
    let ext = URL(fileURLWithPath: sourcePath).pathExtension
    let name = ext.isEmpty ? "\(id).bin" : "\(id).\(ext)"
    let path = directory + name
    try FileManager.default.copyItem(atPath: sourcePath, toPath: path)
    return (id, path)
}
