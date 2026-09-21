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

/// Stages `job.opponent` under `workDir` and returns the opponent directory,
/// or nil when the job has no opponent (an ordinary run: nothing is created).
///
/// Throws when the job says an opponent is needed and it cannot be staged —
/// no support file named, a name that is not a bare filename, or a file the
/// test setup does not contain. Each is reported as the job's build failure
/// with a message that names the fix, because a match graded with nobody on
/// the other side would read as a win.
func stageOpponentWorkspace(job: Job, workDir: URL, testSetupDir: URL) throws -> URL? {
    guard let opponent = job.opponent else { return nil }
    guard let named = opponent.supportFile, !named.isEmpty else {
        throw WorkerDaemonError.opponentFileNotChosen
    }
    guard let filename = FilenameSafety.bareFilename(named) else {
        throw WorkerDaemonError.opponentFileNotBare(named)
    }
    let source = testSetupDir.appendingPathComponent(filename)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: source.path) else {
        throw WorkerDaemonError.opponentFileMissing(filename)
    }
    let opponentDir = workDir.appendingPathComponent("opponent", isDirectory: true)
    try fileManager.createDirectory(at: opponentDir, withIntermediateDirectories: true)
    try fileManager.copyItem(at: source, to: opponentDir.appendingPathComponent(filename))
    return opponentDir
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
