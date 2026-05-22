// APIServer/Utilities/DiskUsage.swift
//
// On-disk footprint measurement for the admin storage panel.  Walks the
// server's data directories and queries the database size so an operator can
// see where the persistent volume is being consumed without shelling into the
// box.  The directory walks are blocking, so callers offload them to the
// thread pool (see AdminRoutes.dashboard).

import Fluent
import Foundation
import SQLKit

/// Recursive size of every regular file under `path`.  Returns 0 for a
/// missing directory so a not-yet-created sink shows as empty rather than
/// breaking the panel.
func directorySizeBytes(at path: String) -> Int {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        )
    else {
        return 0
    }
    var total = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else { continue }
        total += size
    }
    return total
}

/// Size of a single file (e.g. a SQLite database), 0 if absent.
func fileSizeBytes(at path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
}

/// Bytes of the top-level regular files in `path`, bucketed by the filename
/// component before the first ".".  Submissions and test-setup archives are
/// stored flat as `<id>.<ext>` (e.g. `sub_ab12cd34.zip`, `setup_ab12cd34.ipynb`),
/// so this attributes each file's bytes to its owning submission/setup id.
func topLevelFileSizesByID(inDirectory path: String) -> [String: Int] {
    let base = path.hasSuffix("/") ? path : path + "/"
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [:] }
    var result: [String: Int] = [:]
    for entry in entries {
        let full = base + entry
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
        let id = entry.split(separator: ".", maxSplits: 1).first.map(String.init) ?? entry
        result[id, default: 0] += fileSizeBytes(at: full)
    }
    return result
}

/// Per-test-setup on-disk footprint keyed by setup id.  Sums the flat
/// `<id>.<ext>` archives/notebooks at the top level plus the per-setup
/// `shared/<id>/` (extracted support files) and `notebooks/<id>/` (draft
/// notebooks) subtrees.
func testSetupSizesByID(testSetupsDirectory dir: String) -> [String: Int] {
    var result = topLevelFileSizesByID(inDirectory: dir)
    let base = dir.hasSuffix("/") ? dir : dir + "/"
    let fm = FileManager.default
    for subtree in ["shared", "notebooks"] {
        let subtreeDir = base + subtree
        guard let setupDirs = try? fm.contentsOfDirectory(atPath: subtreeDir) else { continue }
        for setupID in setupDirs {
            let full = subtreeDir + "/" + setupID
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            result[setupID, default: 0] += directorySizeBytes(at: full)
        }
    }
    return result
}

/// Best-effort database footprint.
/// - Postgres: `pg_database_size(current_database())` (logical size).
/// - SQLite: the db file plus its `-wal` / `-shm` sidecars.
/// Returns nil when the size can't be determined.
func databaseSizeBytes(on db: Database, settings: DatabaseSettings) async -> Int? {
    switch settings.backend {
    case .postgres:
        guard let sql = db as? SQLDatabase else { return nil }
        struct SizeRow: Decodable { let size: Int }
        let row = try? await sql.raw("SELECT pg_database_size(current_database()) AS size")
            .first(decoding: SizeRow.self)
        return row?.size
    case .sqlite:
        guard let path = settings.sqlitePath else { return nil }
        let main = fileSizeBytes(at: path)
        return main + fileSizeBytes(at: path + "-wal") + fileSizeBytes(at: path + "-shm")
    }
}

/// Human-readable byte count (e.g. "0 B", "12.4 MB", "1.3 GB").
func humanReadableBytes(_ bytes: Int) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 {
        return "\(bytes) B"
    }
    return String(format: "%.1f %@", value, units[unit])
}
