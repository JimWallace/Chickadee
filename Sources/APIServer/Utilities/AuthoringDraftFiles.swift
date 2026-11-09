// APIServer/Utilities/AuthoringDraftFiles.swift
//
// The file-level rule for a staff authoring draft on the server-backed editor
// drive (#2925).
//
// With the server drive, a staff member's working copy of the starter or the
// solution is a draft: the editor autosaves into it, and only "Save to
// assignment" publishes it. The stored notebook can also change elsewhere (an
// MCP edit, another author's save, a version restore). To tell those apart, the
// server keeps a *base* beside each draft: the seed the draft was last in sync
// with. On a page load:
//
//   - stored == base: nothing changed elsewhere. The draft opens as it was,
//     with any unpublished edits.
//   - stored != base, and the draft has no unpublished edits (draft == base,
//     or it already equals the stored seed): the draft is replaced by the new
//     stored notebook.
//   - stored != base, and the draft has unpublished edits: the draft is kept
//     as a separate dated notebook beside it, and the stored notebook opens.
//     Nothing is lost, and a stale draft is never saved over a newer version
//     by accident.
//
// With no base on record (a draft from before #2925), a draft that equals the
// seed is in sync; any other draft is treated as having unpublished edits.

import Foundation

/// What `AuthoringDraftFiles.reconcile` did to a draft.
enum AuthoringDraftOutcome: Equatable, Sendable {
    /// No draft existed; it was seeded.
    case seeded
    /// The draft was kept as it was.
    case kept
    /// The stored notebook changed and the draft had no unpublished edits, so
    /// the draft now holds the stored notebook.
    case refreshed
    /// The stored notebook changed and the draft had unpublished edits. They
    /// were kept in the named file, beside the draft.
    case backedUp(fileName: String)
}

enum AuthoringDraftFiles {
    /// Reconciles the draft at `draftPath` with `seed`, the stored notebook as
    /// the editor would open it now, using the base at `basePath`. `same`
    /// compares two notebooks as documents (`sameNotebookContent`).
    static func reconcile(
        draftPath: String,
        basePath: String,
        seed: Data,
        now: Date,
        same: (Data, Data) -> Bool
    ) throws -> AuthoringDraftOutcome {
        let fileManager = FileManager.default
        let draftURL = URL(fileURLWithPath: draftPath)
        try fileManager.createDirectory(
            at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let draft = try? Data(contentsOf: draftURL), !draft.isEmpty else {
            try seed.write(to: draftURL)
            try recordBase(seed, at: basePath)
            return .seeded
        }
        let base = try? Data(contentsOf: URL(fileURLWithPath: basePath))

        if let base, same(seed, base) {
            return .kept
        }
        if same(draft, seed) {
            try recordBase(seed, at: basePath)
            return base == nil ? .kept : .refreshed
        }
        if let base, same(draft, base) {
            try seed.write(to: draftURL)
            try recordBase(seed, at: basePath)
            return .refreshed
        }

        // Unpublished edits on a draft whose stored notebook has moved on.
        let backupURL = backupURL(for: draftURL, at: now)
        try draft.write(to: backupURL)
        try seed.write(to: draftURL)
        try recordBase(seed, at: basePath)
        return .backedUp(fileName: backupURL.lastPathComponent)
    }

    /// Copies the draft at `draftPath` to a dated backup beside it, before a
    /// write that would replace it, and returns the backup's name (nil when
    /// there is no draft).
    static func backUp(draftPath: String, now: Date) throws -> String? {
        let draftURL = URL(fileURLWithPath: draftPath)
        guard let draft = try? Data(contentsOf: draftURL), !draft.isEmpty else { return nil }
        let backupURL = backupURL(for: draftURL, at: now)
        try draft.write(to: backupURL)
        return backupURL.lastPathComponent
    }

    /// The newest backup of the draft at `draftPath` modified after `since`,
    /// or nil. The page links it until it ages out, so a reload does not lose
    /// the only pointer to it.
    static func newestBackup(draftPath: String, since: Date) -> String? {
        let draftURL = URL(fileURLWithPath: draftPath)
        let directory = draftURL.deletingLastPathComponent()
        let prefix = draftURL.deletingPathExtension().lastPathComponent + " (unsaved draft "
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return
            names
            .filter { $0.hasPrefix(prefix) }
            .compactMap { name -> (String, Date)? in
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(name).path)
                guard let modified = attributes?[.modificationDate] as? Date, modified > since else { return nil }
                return (name, modified)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Records `base` as what the draft is now in sync with.
    static func recordBase(_ base: Data, at basePath: String) throws {
        let baseURL = URL(fileURLWithPath: basePath)
        try FileManager.default.createDirectory(
            at: baseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try base.write(to: baseURL, options: .atomic)
    }

    /// `assignment.ipynb` becomes `assignment (unsaved draft 2026-11-09 1402).ipynb`,
    /// with a counter when that name is taken.
    static func backupURL(for draftURL: URL, at now: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let stamp = String(
            format: "%04d-%02d-%02d %02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        let directory = draftURL.deletingLastPathComponent()
        let stem = draftURL.deletingPathExtension().lastPathComponent
        let ext = draftURL.pathExtension
        for index in 0..<100 {
            let suffix = index == 0 ? "" : " \(index + 1)"
            let name = "\(stem) (unsaved draft \(stamp)\(suffix)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if (try? FileManager.default.attributesOfItem(atPath: candidate.path)) == nil {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(stem) (unsaved draft \(stamp) \(UUID().uuidString)).\(ext)")
    }
}
