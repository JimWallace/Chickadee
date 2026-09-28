// APIServer/Helpers/SupportFileNames.swift
//
// One answer to "which files in this setup are support files": every zip
// entry that is neither a graded suite script nor one of the two reserved
// notebook names. `get_support_files` lists these, and the class-activity
// opponent picker offers exactly these, so the two cannot disagree about
// what an instructor may choose as the bot.

import Core

/// Zip entry names a setup reserves for its notebooks; never support files.
let reservedSetupEntryNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]

/// The setup's support-file names, sorted.
func currentSupportFileNames(setup: APITestSetup) async -> [String] {
    let suiteScripts = Set(setup.decodedManifest()?.testSuites.map(\.script) ?? [])
    return await listZipEntries(zipPath: setup.zipPath)
        .filter { !suiteScripts.contains($0) && !reservedSetupEntryNames.contains($0) }
        .sorted()
}
