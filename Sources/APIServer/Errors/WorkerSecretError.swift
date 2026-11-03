// APIServer/Errors/WorkerSecretError.swift
//
// Why the server could not start with an auto-generated runner secret
// (#2776). Each case stops startup: a secret that is not saved changes on
// the next restart, and every runner then fails HMAC auth.

enum WorkerSecretError: Error, Equatable, CustomStringConvertible {
    /// The diceware wordlist is missing or too short to give a strong
    /// three-word passphrase.
    case wordlistTooShort(path: String, wordCount: Int)
    /// The generated secret could not be saved to the secret file.
    case notPersisted(path: String, reason: String)

    var description: String {
        switch self {
        case .wordlistTooShort(let path, let wordCount):
            "The worker secret wordlist at \(path) has \(wordCount) words; at least "
                + "\(minimumDicewareWordCount) are needed to generate a runner secret. "
                + "Restore the file, or set RUNNER_SHARED_SECRET."
        case .notPersisted(let path, let reason):
            "The generated worker secret could not be saved to \(path) (\(reason)). "
                + "A restart would generate a different secret, and runners would fail auth. "
                + "Make the file writable, or set RUNNER_SHARED_SECRET."
        }
    }
}

/// The fewest diceware words that `randomWorkerPassphrase` accepts.
let minimumDicewareWordCount = 2048
