// APIServer/Services/AssignmentVersionSnapshot.swift
//
// The in-memory form of one content snapshot, plus the builder that produces it
// from a live test setup (docs/assignment-versioning.md).
//
// A snapshot is exactly the three artifacts that make up an assignment's
// content — the manifest, the setup zip's entries, and the starter notebook.
// Everything else the server keeps for an assignment (`shared/{setupID}/`, the
// generated `solution.py`, per-student notebook materializations, runner cache
// entries) re-derives from those three, so capturing them is unnecessary and
// would only create a second source of truth.

import Core
import Foundation

/// One captured content state. Byte payloads live in the blob store; this holds
/// the manifest inline plus the hashes that name the blobs.
struct AssignmentVersionSnapshot: Sendable, Equatable {
    let manifest: String
    let manifestHash: String
    /// Zip entry path → blob hash.
    let fileMap: [String: String]
    /// Blob hash of the starter notebook, nil when the setup has none.
    let notebookHash: String?
    /// Digest over the whole snapshot; the dedupe key.
    let snapshotHash: String

    init(manifest: String, fileMap: [String: String], notebookHash: String?) {
        self.manifest = manifest
        // Module-qualified: the stored property shadows the free function of
        // the same name inside this initializer.
        self.manifestHash = APIServer.manifestHash(manifest)
        self.fileMap = fileMap
        self.notebookHash = notebookHash
        self.snapshotHash = Self.digest(
            manifestHash: self.manifestHash, fileMap: fileMap, notebookHash: notebookHash)
    }

    /// Stable digest over the snapshot's identity.
    ///
    /// The serialization is canonical — file entries sorted by path, fixed
    /// separators — so two snapshots of identical content always produce the
    /// same digest regardless of directory-walk order. That is what makes the
    /// dedupe check in `AssignmentVersionStore.record` reliable rather than
    /// merely usually-right.
    private static func digest(
        manifestHash: String, fileMap: [String: String], notebookHash: String?
    ) -> String {
        var canonical = "manifest:\(manifestHash)\n"
        canonical += "notebook:\(notebookHash ?? "-")\n"
        for path in fileMap.keys.sorted() {
            canonical += "file:\(path)\u{0}\(fileMap[path] ?? "")\n"
        }
        return sha256HexDigest(canonical)
    }

    /// The file map as the JSON stored in `assignment_versions.file_map`.
    /// Sorted keys so the column bytes are stable for identical content.
    func encodedFileMap() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(fileMap),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

enum AssignmentVersionSnapshotError: Error, CustomStringConvertible {
    case zipUnreadable(path: String, reason: String)

    var description: String {
        switch self {
        case .zipUnreadable(let path, let reason):
            return "Could not read setup zip at \(path): \(reason)"
        }
    }
}

enum AssignmentVersionSnapshotBuilder {
    /// Captures `setup`'s current content into blobs and returns the snapshot
    /// describing it.
    ///
    /// The zip is extracted once into a temp directory and walked, rather than
    /// shelling out to `unzip -p` per entry: a suite with fifty generated
    /// scripts would otherwise spawn fifty subprocesses on every content edit.
    ///
    /// A missing zip yields an empty file map rather than throwing. An
    /// assignment with no test setup zip on disk is a legitimate (if degraded)
    /// state, and refusing to snapshot it would mean the one state you most
    /// want a record of is the one state that produces none.
    static func build(
        setup: APITestSetup, blobs: AssignmentVersionBlobStore
    ) async throws -> AssignmentVersionSnapshot {
        let fileMap = try await captureZipEntries(zipPath: setup.zipPath, blobs: blobs)

        var notebookHash: String?
        if let notebookPath = setup.notebookPath, !notebookPath.isEmpty,
            FileManager.default.fileExists(atPath: notebookPath)
        {
            notebookHash = try blobs.putFile(at: notebookPath)
        }

        return AssignmentVersionSnapshot(
            manifest: setup.manifest, fileMap: fileMap, notebookHash: notebookHash)
    }

    /// True when `zipPath` is a valid, empty archive rather than a corrupt one.
    ///
    /// Sized against the canonical 22-byte end-of-central-directory record
    /// `writeEmptyZip` emits; the small slack allows a trailing comment without
    /// admitting anything that could hold real entries.
    private static func isEmptyArchive(zipPath: String) -> Bool {
        guard listZipEntries(zipPath: zipPath).isEmpty else { return false }
        let size =
            (try? FileManager.default.attributesOfItem(atPath: zipPath))?[.size] as? Int ?? .max
        return size <= 64
    }

    /// Extracts the zip to a temp directory, stores every regular file as a
    /// blob, and returns the path → hash map.
    private static func captureZipEntries(
        zipPath: String, blobs: AssignmentVersionBlobStore
    ) async throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: zipPath) else { return [:] }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("chickadee-version-snapshot-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: workDir) }

        do {
            try await extractZipArchive(zipPath: zipPath, into: workDir)
        } catch {
            // `unzip` exits non-zero on a VALID but empty archive ("zipfile is
            // empty"), and an empty setup is a legitimate state — a brand-new
            // from-scratch assignment has one, and so does a suite whose last
            // script was just deleted. Treating that as unreadable meant the
            // first version of every from-scratch assignment silently failed to
            // record. The size check is what keeps this from also swallowing a
            // genuinely corrupt archive: `writeEmptyZip` emits exactly the
            // 22-byte end-of-central-directory record, and no real archive
            // fits in that.
            guard isEmptyArchive(zipPath: zipPath) else {
                throw AssignmentVersionSnapshotError.zipUnreadable(
                    path: zipPath, reason: "\(error)")
            }
            return [:]
        }

        let rootPath = workDir.standardized.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard
            let walker = fileManager.enumerator(
                at: workDir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }

        var map: [String: String] = [:]
        for case let url as URL in walker {
            // Directories and symlinks carry no content worth versioning, and a
            // symlink's target is either already captured as its own entry or
            // points outside the snapshot entirely.
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let full = url.standardized.path
            guard full.hasPrefix(prefix) else { continue }
            map[String(full.dropFirst(prefix.count))] = try blobs.putFile(at: full)
        }
        return map
    }
}
