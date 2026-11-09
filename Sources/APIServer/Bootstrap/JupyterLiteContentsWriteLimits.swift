// APIServer/Bootstrap/JupyterLiteContentsWriteLimits.swift
//
// The two limits on the editor's contents write routes (#2926,
// JupyterLiteContentsRoutes+Write.swift): a per-user storage quota and a
// per-user rate limit. They are constants, not configuration: no environment
// variable sets them (root CLAUDE.md, "What Not To Do"). Each refusal logs a
// structured line, so production data can set better numbers here. Tests
// replace them on `Application`.

import Vapor

struct JupyterLiteContentsWriteLimits: Sendable {
    /// The most bytes a user's own files may take under `users/<id>/`. It
    /// counts only what the write routes can write: symlinks, the delivered
    /// datasets and support files, and the server's `view-`/`preview-`
    /// records are not counted (`UserFolderUsage`).
    let maxUserFolderBytes: Int

    /// The most write requests (PUT, POST, PATCH, DELETE) one user may make
    /// in a sliding 60-second window. An autosave is about five requests per
    /// 120 seconds; the kernel adds one PUT per file it closes, so a loop
    /// that saves many plots can burst.
    let writesPerMinute: Int

    static let `default` = JupyterLiteContentsWriteLimits(
        maxUserFolderBytes: 10 * 1024 * 1024,
        writesPerMinute: 240
    )
}

private struct JupyterLiteContentsWriteLimitsKey: StorageKey {
    typealias Value = JupyterLiteContentsWriteLimits
}

extension Application {
    var jupyterLiteContentsWriteLimits: JupyterLiteContentsWriteLimits {
        get { storage[JupyterLiteContentsWriteLimitsKey.self] ?? .default }
        set { storage[JupyterLiteContentsWriteLimitsKey.self] = newValue }
    }
}
