// APIServer/Utilities/DatasetPartStore.swift
//
// The stored parts of a partitioned dataset, written once per setup and source
// so each student's editor working copy can link to its own part
// (`DatasetDeliveryMode.perPart`, docs/dataset-shared-delivery.md):
//
//     {testSetupsDirectory}dataset-parts/<setupID>/<fingerprint>/header.csv
//     {testSetupsDirectory}dataset-parts/<setupID>/<fingerprint>/part-<k>.csv
//
// - The fingerprint hashes the spec and the source file's identity, so a new
//   source or a new part count is a new directory. A published directory is
//   never written again, so a student's link never points at a part being
//   rewritten.
// - A directory is written under a temporary name and renamed into place, so
//   two students who open at once cannot read a half-written part.
// - It is not under `shared/<setupID>/`, which every setup save removes.
//
// The bytes are `DatasetMaterializer.allParts`, which is the same split the
// worker grades (`DatasetPartStoreTests` pins it).

import Core
import Foundation

/// Why the parts of a dataset could not be stored.
enum DatasetPartStoreError: Error, Equatable {
    case sourceUnreadable(path: String)
    case writeFailed(path: String, reason: String)
}

enum DatasetPartStore {

    /// The name of the header-only file: what a class-composite student who
    /// holds no part yet reads (`DatasetDeals.holdsNoPartYet`).
    static let headerFileName = "header.csv"

    /// How long a fingerprint directory is kept after a sweep first finds it
    /// no longer current, so a student still linked to it is relinked on
    /// their next visit before it goes.
    static let staleRetention: TimeInterval = 24 * 60 * 60

    /// The marker a sweep writes into a directory the first time it finds it
    /// no longer current. Its modification time is when retention starts.
    static let supersededMarkerName = ".superseded"

    /// The file name of part `part`.
    static func partFileName(_ part: Int) -> String { "part-\(part).csv" }

    /// The directory holding every setup's parts.
    static func root(testSetupsDirectory: String) -> String {
        (testSetupsDirectory.hasSuffix("/") ? testSetupsDirectory : testSetupsDirectory + "/") + "dataset-parts/"
    }

    /// The fingerprint of `spec` over the source at `sourcePath`, or nil when
    /// the source is missing. It folds the whole spec and the source's
    /// modification time, size and file number. A setup save re-extracts the
    /// source as a new file, so even an edit that kept the size and the time
    /// gets a new fingerprint; the stored parts are never served stale.
    static func fingerprint(
        spec: DatasetSpec, sourcePath: String, fileManager fm: FileManager = .default
    ) -> String? {
        guard let attrs = try? fm.attributesOfItem(atPath: sourcePath) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let size = (attrs[.size] as? Int) ?? -1
        // Interpolated rather than cast: its numeric type differs between
        // Foundation on macOS and on Linux.
        let fileNumber = attrs[.systemFileNumber].map { "\($0)" } ?? "-"
        guard let encoded = try? ManifestCodec.stableEncoder.encode(spec),
            let specText = String(bytes: encoded, encoding: .utf8)
        else { return nil }
        return String(sha256HexDigest("\(specText)|\(mtime)|\(size)|\(fileNumber)").prefix(24))
    }

    /// The directory of one fingerprint.
    static func directory(root: String, setupID: String, fingerprint: String) -> String {
        root + setupID + "/" + fingerprint + "/"
    }

    /// Writes the parts of `spec` from `sourcePath` into the fingerprint's
    /// directory, unless they are already there, and returns that directory.
    /// After a new directory is published, older fingerprints of the setup
    /// that `keeping` does not name are swept.
    static func ensureParts(
        spec: DatasetSpec, sourcePath: String, root: String, setupID: String, fingerprint: String,
        keeping: Set<String>, now: Date = Date(), fileManager fm: FileManager = .default
    ) throws(DatasetPartStoreError) -> String {
        let target = directory(root: root, setupID: setupID, fingerprint: fingerprint)
        if fm.fileExists(atPath: target + headerFileName) { return target }

        guard let partCount = spec.partCount, partCount > 0,
            let source = try? String(contentsOfFile: sourcePath, encoding: .utf8)
        else { throw .sourceUnreadable(path: sourcePath) }

        let setupDir = root + setupID + "/"
        let staging = setupDir + ".tmp-\(UUID().uuidString)/"
        do {
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
            try DatasetMaterializer.headerOnly(source)
                .write(toFile: staging + headerFileName, atomically: false, encoding: .utf8)
            for (part, bytes) in DatasetMaterializer.allParts(csv: source, partCount: partCount).enumerated() {
                try bytes.write(toFile: staging + partFileName(part), atomically: false, encoding: .utf8)
            }
        } catch {
            try? fm.removeItem(atPath: staging)
            throw .writeFailed(path: staging, reason: error.localizedDescription)
        }

        do {
            try fm.moveItem(atPath: staging, toPath: target)
        } catch {
            try? fm.removeItem(atPath: staging)
            // Another visit published the same fingerprint first: its parts
            // are the same bytes.
            guard fm.fileExists(atPath: target + headerFileName) else {
                throw .writeFailed(path: target, reason: error.localizedDescription)
            }
            return target
        }
        sweep(setupDirectory: setupDir, keeping: keeping.union([fingerprint]), now: now, fileManager: fm)
        return target
    }

    /// Ages out the directories of a setup that `keeping` does not name. A
    /// fingerprint directory is marked the first time a sweep finds it no
    /// longer current, and removed once the mark is older than
    /// `staleRetention`; a directory that is current again loses its mark.
    /// A staging directory left by a failed write is removed once it is that
    /// old. A sweep failure is not an error: the next publish sweeps again.
    static func sweep(
        setupDirectory: String, keeping: Set<String>, now: Date, fileManager fm: FileManager = .default
    ) {
        guard let entries = try? fm.contentsOfDirectory(atPath: setupDirectory) else { return }
        for entry in entries {
            let path = setupDirectory + entry + "/"
            let marker = path + supersededMarkerName
            if keeping.contains(entry) {
                try? fm.removeItem(atPath: marker)
                continue
            }
            let ageSource = entry.hasPrefix(".tmp-") ? path : marker
            guard let since = (try? fm.attributesOfItem(atPath: ageSource))?[.modificationDate] as? Date else {
                // Not marked yet: retention starts now.
                _ = fm.createFile(atPath: marker, contents: nil)
                continue
            }
            guard now.timeIntervalSince(since) > staleRetention else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
