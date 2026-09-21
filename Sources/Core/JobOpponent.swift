// Core/JobOpponent.swift
//
// What a match job carries about its opponent (docs/class-activities.md,
// "Runner contract"). Defined in Core so the server writes it and the worker
// reads it without either learning the other's types.
//
// STRUCTURAL ON PURPOSE. The manifest's `activity` block is stripped from the
// runner-facing manifest because an `ActivityKind` a runner's build predates
// would fail the whole manifest in the enum decoder. This descriptor names no
// kind and no opponent-source enum: it says which support file to stage and
// what seed to hand the script, and a later opponent source (a classmate's
// submission, a champion) adds its own optional field beside `supportFile`
// rather than a case a runner may not know.

import Foundation

/// The opponent staged beside a submission for one match job. Nil on the job
/// means an ordinary run with no opponent directory and no match seed.
public struct JobOpponent: Codable, Equatable, Sendable {
    /// The bare filename of the support file in the test setup to stage as the
    /// opponent's workspace. Nil when the activity needs an opponent but the
    /// instructor has not chosen one yet — the worker then fails the job with
    /// a message naming the fix, rather than grading a match with nobody on
    /// the other side.
    public let supportFile: String?

    /// The per-match seed, `CHICKADEE_MATCH_SEED` to the script. Derived from
    /// the submission and the opponent's identity by `matchSeed`, so a re-test
    /// replays the same trials and two students never share one.
    public let matchSeed: String

    public init(supportFile: String?, matchSeed: String) {
        self.supportFile = supportFile
        self.matchSeed = matchSeed
    }

    /// The seed for one (submission, opponent) pair: 64 lowercase hex
    /// characters, the same shape as the assignment seed, so a script can
    /// treat the two alike.
    ///
    /// `opponentIdentity` is whatever names the opponent in a stable way — the
    /// support file's name for a bot, a submission ID for a classmate — with
    /// the source spelled in front so a bot called `abc123` and a submission
    /// `abc123` never collide.
    public static func matchSeed(submissionID: String, opponentIdentity: String) -> String {
        sha256HexDigest("chickadee-match\n\(submissionID)\n\(opponentIdentity)")
    }

    /// The identity a bundled bot has in `matchSeed`. One spelling, shared by
    /// the server that derives the seed and any test that pins it.
    public static func supportFileIdentity(_ filename: String?) -> String {
        "supportFile:\(filename ?? "")"
    }
}
