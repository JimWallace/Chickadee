// APIServer/Services/WorkingCopyProtectedFiles.swift
//
// The files in a student's working copy (`jupyterlite/files/users/<id>/<setupID>/`)
// that only the server writes. The server-backed editor drive (#469) lets the
// editor and the kernel write the working copy, so its write routes refuse these
// paths:
//
// - every file the setup delivers (`StudentWorkspaceFiles.delivered`): the
//   per-student dataset files and the support files. A dataset is a real file
//   that the materialization pass does not rewrite while its fingerprint is
//   current, and a support-file name is never relinked over a real file, so a
//   student's write to either would persist and no reset would repair it;
// - the records the server writes for viewing: `view-<submissionID>.ipynb` and
//   staff `preview-<token>.ipynb`.
//
// A student's own new files are not protected, and the notebook is not.

import Core
import Fluent
import Foundation
import Vapor

enum WorkingCopyProtectedFiles {
    /// The protected paths of a setup's working copy, relative to its folder.
    /// Empty when the setup does not exist or its manifest does not decode:
    /// such a folder holds nothing the server delivers.
    static func paths(setupID: String, on db: any Database, application: Application) async throws -> Set<String> {
        guard let setup = try await APITestSetup.find(setupID, on: db),
            let manifest = decodeManifest(from: Data(setup.manifest.utf8))
        else { return [] }
        let entries = await application.zipEntryListCache.entries(zipPath: setup.zipPath)
        return StudentWorkspaceFiles.delivered(zipEntries: entries, manifest: manifest)
    }

    /// `paths(setupID:)` for several setups in one database read, keyed by
    /// setup ID. A setup that does not exist or does not decode is absent.
    static func paths(
        setupIDs: [String], on db: any Database, application: Application
    ) async throws -> [String: Set<String>] {
        guard !setupIDs.isEmpty else { return [:] }
        let setups = try await APITestSetup.query(on: db).filter(\.$id ~~ setupIDs).all()
        var result: [String: Set<String>] = [:]
        for setup in setups {
            guard let id = setup.id, let manifest = decodeManifest(from: Data(setup.manifest.utf8)) else { continue }
            let entries = await application.zipEntryListCache.entries(zipPath: setup.zipPath)
            result[id] = StudentWorkspaceFiles.delivered(zipEntries: entries, manifest: manifest)
        }
        return result
    }

    /// True when a write at `relativePath` (inside the setup folder) would
    /// touch a protected file: it names one, lies below one (a dataset turned
    /// into a folder) or holds one (a folder renamed away, or a file put where
    /// a support file's folder must go). Compared without case, because a
    /// macOS file system treats `Cases.CSV` and `cases.csv` as one file.
    static func touchesProtected(_ relativePath: String, in protected: Set<String>) -> Bool {
        let path = relativePath.lowercased()
        let top = path.split(separator: "/").first.map(String.init) ?? path
        if top.hasSuffix(".ipynb"), top.hasPrefix("view-") || top.hasPrefix("preview-") {
            return true
        }
        return protected.contains { file in
            let file = file.lowercased()
            return file == path || path.hasPrefix(file + "/") || file.hasPrefix(path + "/")
        }
    }
}
