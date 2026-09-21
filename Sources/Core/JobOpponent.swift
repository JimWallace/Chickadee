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

    /// The opponent SUBMISSION to stage — the champion's, for king of the hill
    /// — as the worker downloads it: its ID (for the log), the worker download
    /// URL, and the filename it was submitted under (nil for a zip, exactly as
    /// `Job.submissionFilename` is). All nil for a support-file opponent, and
    /// absent from the wire, so a slice-2 descriptor's bytes are unchanged.
    public let submissionID: String?
    public let submissionURL: URL?
    public let submissionFilename: String?

    public init(
        supportFile: String?,
        matchSeed: String,
        submissionID: String? = nil,
        submissionURL: URL? = nil,
        submissionFilename: String? = nil
    ) {
        self.supportFile = supportFile
        self.matchSeed = matchSeed
        self.submissionID = submissionID
        self.submissionURL = submissionURL
        self.submissionFilename = submissionFilename
    }

    private enum CodingKeys: String, CodingKey {
        case supportFile, matchSeed, submissionID, submissionURL, submissionFilename
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportFile = try c.decodeIfPresent(String.self, forKey: .supportFile)
        matchSeed = try c.decode(String.self, forKey: .matchSeed)
        submissionID = try c.decodeIfPresent(String.self, forKey: .submissionID)
        submissionURL = try c.decodeIfPresent(URL.self, forKey: .submissionURL)
        submissionFilename = try c.decodeIfPresent(String.self, forKey: .submissionFilename)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(supportFile, forKey: .supportFile)
        try c.encode(matchSeed, forKey: .matchSeed)
        try c.encodeIfPresent(submissionID, forKey: .submissionID)
        try c.encodeIfPresent(submissionURL, forKey: .submissionURL)
        try c.encodeIfPresent(submissionFilename, forKey: .submissionFilename)
    }

    /// True when the opponent is another submission rather than a bundled
    /// file — what the worker asks to decide whether there is a download.
    public var stagesASubmission: Bool { submissionURL != nil }

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

    /// The identity a champion's submission has in `matchSeed`, and the key a
    /// match row is stored under (`match_results.opponent_identity`).
    public static func submissionIdentity(_ submissionID: String) -> String {
        "submission:\(submissionID)"
    }

    /// The identity of an empty hill — no champion and no bot. A match row is
    /// still written, so the first passing match can claim it.
    public static let noOpponentIdentity = "none"
}
