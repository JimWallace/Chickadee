// APIServer/Services/DatasetOverlayDirectory.swift
//
// A private view of an assignment's support files in which every per-student
// dataset carries THIS student's slice.
//
// `PersonalizationEvaluator` spawns its interpreter with the cwd set to the
// support-files directory so an expression can `open("cases.csv")`.  That
// directory is shared by every student and holds the instructor's full pool, so
// evaluating there answered a per-student question with the pool's data — see
// docs/datasets.md, "Expressions read the student's slice, not the pool".
//
// Kept out of the evaluator because it is a different job (staging a directory,
// not running an interpreter) and because the evaluator is already at its type
// body limit.

import Core
import Foundation

enum DatasetOverlayDirectory {

    /// The directory an evaluation should run in: `supportFilesDirectory` itself
    /// when nothing is personalized, otherwise a private overlay of it in which
    /// every file in `datasetFiles` carries the student's slice.
    ///
    /// Returning the shared directory for the empty case is what keeps every
    /// non-dataset assignment byte-for-byte unchanged, and it lives here rather
    /// than at the call site so there is one answer to "where does this run".
    ///
    /// Everything the student does not personalize is a symlink to the shared
    /// copy — cheap next to the subprocess this is setting up, and it keeps the
    /// pool a single stored copy rather than one per evaluation.
    ///
    /// A dataset file whose slice cannot be written is left ABSENT rather than
    /// symlinked to the pool: the expression then fails loudly ("no such file")
    /// instead of quietly computing the instructor's answer and shipping it to
    /// the student as their own, which is the defect this overlay exists to fix.
    static func root(
        over supportFilesDirectory: String,
        datasetFiles: [String: String],
        in tempDir: URL,
        fm: FileManager = .default
    ) -> URL {
        let shared = URL(fileURLWithPath: supportFilesDirectory, isDirectory: true)
        guard !datasetFiles.isEmpty else { return shared }
        let overlay = tempDir.appendingPathComponent("support", isDirectory: true)
        do {
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        } catch {
            return shared
        }

        for entry in (try? fm.contentsOfDirectory(atPath: supportFilesDirectory)) ?? [] {
            guard datasetFiles[entry] == nil else { continue }
            try? fm.createSymbolicLink(
                at: overlay.appendingPathComponent(entry),
                withDestinationURL: shared.appendingPathComponent(entry))
        }
        for (name, contents) in datasetFiles {
            // A dataset name is a bare filename by construction (`putDatasets`
            // and `DatasetResolver` both refuse path components), but this joins
            // onto a directory, so re-check rather than inherit the guarantee.
            guard FilenameSafety.bareFilename(name) != nil else { continue }
            try? contents.write(
                to: overlay.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return overlay
    }
}
