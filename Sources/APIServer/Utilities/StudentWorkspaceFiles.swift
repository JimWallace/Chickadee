// APIServer/Utilities/StudentWorkspaceFiles.swift
//
// Which of a setup's files a student's notebook working copy holds. The
// working-copy pass (`createSupportFileSymlinks`) links the support files, and
// `writeDatasetFiles` places each dataset: a link for one every student
// receives whole, a file of the student's own otherwise
// (docs/dataset-shared-delivery.md). The
// `files.missing` authoring check (#2747) asks the same question, so the rule
// is stated once, here.

import Core

enum StudentWorkspaceFiles {
    /// The zip entries the working copy links: every entry except a suite
    /// script, a reserved notebook, a grader-only file (withheld from every
    /// student-facing path, docs/datasets.md option B) and a dataset (placed
    /// by `writeDatasetFiles`, which owns its form, so this pass must not
    /// shadow it).
    static func linkedSupportFiles(zipEntries: [String], manifest: TestProperties) -> [String] {
        let scripts = Set(manifest.testSuites.map(\.script))
        let graderOnly = manifest.graderOnlyFileSet
        let datasets = Set(manifest.datasets.map(\.file))
        return zipEntries.filter {
            !scripts.contains($0) && !reservedSetupEntryNames.contains($0) && !graderOnly.contains($0)
                && !datasets.contains($0)
        }
    }

    /// Every file a student's working copy holds: the linked support files and
    /// the datasets. A dataset is written whatever its grader-only mark.
    static func delivered(zipEntries: [String], manifest: TestProperties) -> Set<String> {
        Set(linkedSupportFiles(zipEntries: zipEntries, manifest: manifest)).union(manifest.datasets.map(\.file))
    }
}
