// APIServer/Utilities/DatasetWorkingCopyPlacement.swift
//
// Puts one dataset file into a student's editor working copy, either as a link
// to the setup's shared extraction or as a real file of the student's own
// (`DatasetDeliveryMode`, docs/dataset-shared-delivery.md). Each operation
// replaces whatever is at the path, so a working copy moves between the two
// forms when an author adds or removes a sample.
//
// The one rule that matters: a real-file write never goes through a link. A
// link at the path points at the shared copy that every student reads, so a
// write through it would hand one student's rows to the whole class. The link
// is removed first, and `DatasetWorkingCopyPlacementTests` pins that the shared
// copy keeps its bytes.

import Foundation

/// Why a dataset file could not be put into a working copy.
enum DatasetWorkingCopyPlacementError: Error, Equatable {
    case linkFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
}

enum DatasetWorkingCopyPlacement {

    /// Makes `path` a link to `target`. A link that already points there is
    /// left alone; a real file or a link elsewhere is replaced.
    static func link(
        _ path: String, to target: String, fileManager fm: FileManager = .default
    ) throws(DatasetWorkingCopyPlacementError) {
        if linkTarget(of: path, fm) == target { return }
        do {
            try removeIfPresent(path, fm)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        } catch {
            // Two visits by the same student can race here. The one that lost
            // still succeeded if the winner made the same link.
            if linkTarget(of: path, fm) == target { return }
            throw .linkFailed(path: path, reason: error.localizedDescription)
        }
    }

    /// Makes `path` a real file holding `contents`. A link at `path` is removed
    /// first, so the write cannot reach the file the link points at.
    static func write(
        _ contents: String, to path: String, fileManager fm: FileManager = .default
    ) throws(DatasetWorkingCopyPlacementError) {
        do {
            if linkTarget(of: path, fm) != nil {
                try fm.removeItem(atPath: path)
            }
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw .writeFailed(path: path, reason: error.localizedDescription)
        }
    }

    /// The target of the link at `path`, or nil when `path` is not a link.
    /// A dangling link still has a target.
    static func linkTarget(of path: String, _ fm: FileManager = .default) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: path)
    }

    /// Removes the file or link at `path`, if there is one. `removeItem` does
    /// not follow a link, so this never removes the shared copy.
    private static func removeIfPresent(_ path: String, _ fm: FileManager) throws {
        guard linkTarget(of: path, fm) != nil || fm.fileExists(atPath: path) else { return }
        try fm.removeItem(atPath: path)
    }
}
