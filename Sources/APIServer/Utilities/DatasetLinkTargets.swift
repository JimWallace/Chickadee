// APIServer/Utilities/DatasetLinkTargets.swift
//
// Where one student's copy of each dataset belongs in their editor working
// copy (docs/dataset-shared-delivery.md): a link to the shared extraction, a
// link to a stored part, or a real file of their own. `writeDatasetFiles`
// places the files from this and its skip check compares against it, so the
// two cannot disagree about what "current" means.

import Core
import Foundation

/// Where a student's copy of one dataset belongs.
enum DatasetCopyTarget: Equatable {
    /// A real file holding the student's own rows (`perStudent`).
    case realFile
    /// A link to `path`. `partsFingerprint` names the stored parts that must
    /// exist first when the path is a stored part, and is nil for a link to
    /// the shared extraction.
    case link(path: String, partsFingerprint: String?)
    /// A link, but its target cannot be named yet because the source is not
    /// in the shared extraction. Nothing is placed; the next visit retries.
    case unavailable
}

/// Why a linked dataset could not be placed.
enum DatasetLinkError: Error, Equatable {
    case parts(DatasetPartStoreError)
    case link(DatasetWorkingCopyPlacementError)
}

struct DatasetLinkTargets: Sendable {
    let sharedDir: String
    let partsRoot: String
    let setupID: String
    let dealNumber: Int?
    /// True for a class-composite student whose slot is not dealt yet
    /// (`DatasetDeals.holdsNoPartYet`): they read a partition's header only.
    let holdsNoPartYet: Bool

    /// Where the student's copy of `spec.file` belongs. Reads only file
    /// metadata, never a file's contents.
    func target(for spec: DatasetSpec, fileManager fm: FileManager = .default) -> DatasetCopyTarget {
        let source = sharedDir + spec.file
        let wholeSource: DatasetCopyTarget =
            fm.fileExists(atPath: source) ? .link(path: source, partsFingerprint: nil) : .unavailable
        switch spec.deliveryMode {
        case .perStudent:
            return .realFile
        case .shared:
            return wholeSource
        case .perPart:
            // The part index is `DatasetSpec.part(forDeal:)`, the rule the
            // materializer uses. With no deal number outside a composite it
            // is nil, and the materializer gives the whole file.
            let part = spec.part(forDeal: dealNumber)
            guard holdsNoPartYet || part != nil else { return wholeSource }
            guard let fingerprint = DatasetPartStore.fingerprint(spec: spec, sourcePath: source, fileManager: fm)
            else { return .unavailable }
            let directory = DatasetPartStore.directory(root: partsRoot, setupID: setupID, fingerprint: fingerprint)
            let name = part.map(DatasetPartStore.partFileName) ?? DatasetPartStore.headerFileName
            return .link(
                path: directory + (holdsNoPartYet ? DatasetPartStore.headerFileName : name),
                partsFingerprint: fingerprint)
        }
    }

    /// The fingerprints of every partition in `datasets` whose source is
    /// present: the parts a sweep must keep.
    func currentFingerprints(of datasets: [DatasetSpec], fileManager fm: FileManager = .default) -> Set<String> {
        Set(
            datasets.filter { $0.deliveryMode == .perPart }.compactMap {
                DatasetPartStore.fingerprint(spec: $0, sourcePath: sharedDir + $0.file, fileManager: fm)
            })
    }

    /// Places a linked dataset: for a stored part, writes the setup's parts
    /// first if they are not stored yet, then links the student's copy. Does
    /// nothing for `.realFile` or `.unavailable`, nor for a source that is not
    /// UTF-8 text, which the resolver also skips.
    func placeLink(
        for spec: DatasetSpec, in studentDir: String, keeping: Set<String>, fileManager fm: FileManager = .default
    ) throws(DatasetLinkError) {
        guard case .link(let path, let partsFingerprint) = target(for: spec, fileManager: fm) else { return }
        if let partsFingerprint {
            do {
                _ = try DatasetPartStore.ensureParts(
                    spec: spec, sourcePath: sharedDir + spec.file, root: partsRoot, setupID: setupID,
                    fingerprint: partsFingerprint, keeping: keeping, fileManager: fm)
            } catch .sourceUnreadable {
                return
            } catch {
                throw .parts(error)
            }
        }
        do {
            try DatasetWorkingCopyPlacement.link(studentDir + "/" + spec.file, to: path, fileManager: fm)
        } catch {
            throw .link(error)
        }
    }
}
