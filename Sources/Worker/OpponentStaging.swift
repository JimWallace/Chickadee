// Worker/OpponentStaging.swift
//
// Stages a match job's opponent beside the grading workspace
// (docs/class-activities.md, "Runner contract"). The script reaches it through
// `CHICKADEE_OPPONENT_DIR`; the seed for the match rides `CHICKADEE_MATCH_SEED`.
//
// The opponent directory lives in the per-job work dir, NOT inside the test
// setup directory: the setup directory is the script's working directory and
// the place the submission is staged, and a stray directory there would be one
// more thing the submission-file candidates and required-file checks had to
// know to ignore. Both sandboxes can read it — the macOS profile reads the
// whole filesystem and the Linux namespaces do not restrict reads — and the
// work dir is removed with the job.

import Core
import Foundation

/// The environment keys a match script reads.
enum OpponentEnvironment {
    static let directory = "CHICKADEE_OPPONENT_DIR"
    static let matchSeed = "CHICKADEE_MATCH_SEED"
}

/// Where the daemon downloads an opponent submission before staging it.
func opponentDownloadDestination(workDir: URL) -> URL {
    workDir.appendingPathComponent("opponent-submission.bin")
}

/// Stages `job.opponent` under `workDir` and returns the opponent directory,
/// or nil when the job has no opponent (an ordinary run: nothing is created).
///
/// A support-file opponent is copied out of the test setup under its own
/// name. A submission opponent (the champion, king of the hill) is staged the
/// way the challenger's own upload is: a raw file lands under its submitted
/// name, a zip is extracted, and every notebook is extracted to the
/// assignment's source language with `.chickadee_student_module` naming the
/// opponent's module — so a match script finds the opponent's code by the
/// same hint the runtimes use for the student's. `downloadedSubmission` is
/// the daemon's download of `opponent.submissionURL`, nil when there was
/// nothing to download.
///
/// Throws when the job says an opponent is needed and it cannot be staged —
/// no support file named, a name that is not a bare filename, a file the
/// test setup does not contain, or a submission download that never landed.
/// Each is reported as the job's build failure with a message that names the
/// fix, because a match graded with nobody on the other side would read as
/// a win.
func stageOpponentWorkspace(
    job: Job, workDir: URL, testSetupDir: URL, downloadedSubmission: URL? = nil
) async throws -> URL? {
    guard let opponent = job.opponent else { return nil }
    let fileManager = FileManager.default
    let opponentDir = workDir.appendingPathComponent("opponent", isDirectory: true)

    if opponent.stagesASubmission {
        guard let downloadedSubmission, fileManager.fileExists(atPath: downloadedSubmission.path) else {
            throw WorkerDaemonError.opponentSubmissionMissing(opponent.submissionID ?? "")
        }
        try fileManager.createDirectory(at: opponentDir, withIntermediateDirectories: true)
        try await stageOpponentSubmission(
            opponent: opponent, downloaded: downloadedSubmission, into: opponentDir,
            manifest: job.manifest)
        return opponentDir
    }

    guard let named = opponent.supportFile, !named.isEmpty else {
        throw WorkerDaemonError.opponentFileNotChosen
    }
    guard let filename = FilenameSafety.bareFilename(named) else {
        throw WorkerDaemonError.opponentFileNotBare(named)
    }
    let source = testSetupDir.appendingPathComponent(filename)
    guard fileManager.fileExists(atPath: source.path) else {
        throw WorkerDaemonError.opponentFileMissing(filename)
    }
    try fileManager.createDirectory(at: opponentDir, withIntermediateDirectories: true)
    try fileManager.copyItem(at: source, to: opponentDir.appendingPathComponent(filename))
    return opponentDir
}

/// The submission half of `stageOpponentWorkspace`: the zip is extracted with
/// the same helper the daemon uses for the challenger.
private func stageOpponentSubmission(
    opponent: JobOpponent, downloaded: URL, into opponentDir: URL, manifest: TestProperties
) async throws {
    let fileManager = FileManager.default
    if let filename = opponent.submissionFilename {
        let dest = stagedSubmissionDestination(submissionDirectory: opponentDir, submittedFilename: filename)
        try? fileManager.removeItem(at: dest)
        try fileManager.copyItem(at: downloaded, to: dest)
    } else {
        try await extractZipArchive(zipPath: downloaded.path, into: opponentDir)
    }
    // The assignment's language owns the extraction, as for the challenger;
    // a nil owner means "trust the notebook's own metadata".
    let language = manifestOwningLanguage(manifest)
    _ = try extractNotebooksToCode(
        in: opponentDir,
        forcedLanguage: language,
        studentNotebookName: opponent.submissionFilename.map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
    // The same hint the runtimes read beside the student's file — see
    // `writeStudentModuleHint` — so a match script can find the opponent's
    // module by name instead of globbing.
    let hintLanguage = language ?? .python
    let module =
        preferredStudentModuleFilename(submissionFilename: opponent.submissionFilename, language: hintLanguage)
        ?? studentModuleFromSubmittedFiles(in: opponentDir, language: hintLanguage)
    let hintURL = opponentDir.appendingPathComponent(".chickadee_student_module")
    try? fileManager.removeItem(at: hintURL)
    if let module, !module.isEmpty {
        try module.write(to: hintURL, atomically: true, encoding: .utf8)
    }
}

/// The environment a match job adds to every script's `CHICKADEE_` namespace.
/// Empty for an ordinary run, so a job with no opponent is byte-for-byte the
/// environment it always had.
func opponentScriptEnvironment(job: Job, opponentDir: URL?) -> [String: String] {
    guard let opponent = job.opponent, let opponentDir else { return [:] }
    return [
        OpponentEnvironment.directory: opponentDir.path,
        OpponentEnvironment.matchSeed: opponent.matchSeed,
    ]
}
