// APIServer/Services/UserFolderUsage.swift
//
// The bytes a user's own files take under `jupyterlite/files/users/<id>/`,
// for the storage quota on the editor's contents write routes (#2926).
//
// Only what the write routes can write is counted. The server's own files are
// left out, because a student near the limit through them could not save and
// could not delete them:
//
// - symlinks (support files and shared dataset folders): the bytes are shared;
// - the files each setup delivers and the `view-`/`preview-` records
//   (`WorkingCopyProtectedFiles`).

import Fluent
import Foundation
import Vapor

enum UserFolderUsage {
    /// The bytes of the user's own files under `userRootPath` (absolute).
    static func writableBytes(
        userRootPath: String, on db: any Database, application: Application
    ) async throws -> Int {
        let rootURL = URL(fileURLWithPath: userRootPath, isDirectory: true).standardizedFileURL
        let setupIDs: [String] = try await runBlocking {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
            return children.filter { !$0.hasPrefix(".") }
        }
        let protected = try await WorkingCopyProtectedFiles.paths(
            setupIDs: setupIDs, on: db, application: application)
        return try await runBlocking { countWritableBytes(rootURL: rootURL, protected: protected) }
    }

    /// The walk itself. A symlink is skipped and never descended into.
    static func countWritableBytes(rootURL: URL, protected: [String: Set<String>]) -> Int {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: keys, options: [])
        else { return 0 }
        let rootComponents = rootURL.resolvingSymlinksInPath().pathComponents
        let rootRaw = rootURL.pathComponents
        var total = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            let components = url.standardizedFileURL.pathComponents
            let inside: ArraySlice<String>
            if components.starts(with: rootRaw) {
                inside = components.dropFirst(rootRaw.count)
            } else if components.starts(with: rootComponents) {
                inside = components.dropFirst(rootComponents.count)
            } else {
                continue
            }
            if inside.count >= 2, let setupID = inside.first {
                let path = inside.dropFirst().joined(separator: "/")
                if WorkingCopyProtectedFiles.touchesProtected(path, in: protected[setupID] ?? []) { continue }
            }
            total += size
        }
        return total
    }
}
