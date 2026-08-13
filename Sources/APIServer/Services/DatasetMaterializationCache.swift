// APIServer/Services/DatasetMaterializationCache.swift
//
// Process-local memo of the last dataset materialization per (user, setup),
// so a notebook visit re-slices and rewrites the per-student dataset files
// only when an input actually changed (#1382 item 3). `writeDatasetFiles`
// used to read the source CSV, recompute the student's slice, and overwrite
// every dataset file on every page visit; the working-copy notebook beside
// those files has always had an already-exists short-circuit.
//
// The fingerprint covers everything that determines the produced bytes —
// the per-student seed, each dataset spec, and each source file's identity
// (mtime + size) — so a staff re-seed, a spec edit, and a re-uploaded
// source each invalidate it, preserving every regeneration trigger the
// always-rewrite had. Target-file existence is checked separately at skip
// time so a student who deletes a dataset file still gets it repaired on
// the next visit. A restart empties the memo, which costs one
// re-materialization per (user, setup) — the same work a first visit does.

import Foundation
import Vapor

actor DatasetMaterializationCache {
    private struct Key: Hashable {
        let userID: UUID
        let setupID: String
    }

    private var fingerprintByKey: [Key: String] = [:]

    /// True when the last recorded materialization for (user, setup) was
    /// produced from exactly these inputs.
    func isCurrent(userID: UUID, setupID: String, fingerprint: String) -> Bool {
        fingerprintByKey[Key(userID: userID, setupID: setupID)] == fingerprint
    }

    /// Records a completed materialization's inputs.
    func record(userID: UUID, setupID: String, fingerprint: String) {
        fingerprintByKey[Key(userID: userID, setupID: setupID)] = fingerprint
    }
}

private struct DatasetMaterializationCacheKey: StorageKey {
    typealias Value = DatasetMaterializationCache
}

extension Application {
    var datasetMaterializationCache: DatasetMaterializationCache {
        get {
            if let existing = storage[DatasetMaterializationCacheKey.self] {
                return existing
            }
            let created = DatasetMaterializationCache()
            storage[DatasetMaterializationCacheKey.self] = created
            return created
        }
        set { storage[DatasetMaterializationCacheKey.self] = newValue }
    }
}
