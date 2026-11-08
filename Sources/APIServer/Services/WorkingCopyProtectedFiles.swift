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
// - the read-only submission records, `view-<submissionID>.ipynb`.
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

    /// True when `relativePath` (inside the setup folder) names a protected
    /// file: a delivered one, or a submission record.
    static func isProtected(_ relativePath: String, in protected: Set<String>) -> Bool {
        if protected.contains(relativePath) { return true }
        return !relativePath.contains("/") && relativePath.hasPrefix("view-") && relativePath.hasSuffix(".ipynb")
    }

    /// True when `relativePath` is a folder that holds a protected file, so a
    /// rename of it would move that file.
    static func holdsProtected(_ relativePath: String, in protected: Set<String>) -> Bool {
        protected.contains { $0.hasPrefix(relativePath + "/") }
    }
}
