// APIServer/GitHub/GitHubLinkError.swift
//
// Each way that linking a GitHub account can fail, with the sentence the
// account page shows.

enum GitHubLinkError: String, Error, Equatable {
    /// No GitHub App is registered, or its secrets are missing.
    case unavailable
    /// The callback `state` does not match the one this session sent.
    case stateMismatch
    /// The student declined on GitHub, or the callback carried no code.
    case cancelled
    /// GitHub refused the code, or its answer could not be read.
    case exchangeFailed
    /// That GitHub account is already linked to another Chickadee account.
    case linkedElsewhere

    var message: String {
        switch self {
        case .unavailable:
            "GitHub linking is not available on this server."
        case .stateMismatch:
            "The GitHub response did not match this session. Link the account again."
        case .cancelled:
            "GitHub did not link the account. Link it again when you are ready."
        case .exchangeFailed:
            "GitHub did not confirm the account. Link it again."
        case .linkedElsewhere:
            "That GitHub account is already linked to another Chickadee account."
        }
    }
}
