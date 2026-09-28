// APIServer/GitHub/GitHubAppRegistrationError.swift
//
// Each way that registering the GitHub App can fail, with the sentence the
// admin page shows.

enum GitHubAppRegistrationError: String, Error, Equatable {
    /// The organization field is not a valid GitHub organization login.
    case invalidOrganization
    /// An App is already registered. There is at most one.
    case alreadyRegistered
    /// The callback `state` does not match the one this session sent.
    case stateMismatch
    /// The callback carried no usable code.
    case missingCode
    /// GitHub refused the code, or its answer could not be read.
    case conversionFailed
    /// The secrets file could not be written.
    case secretsNotWritten

    var message: String {
        switch self {
        case .invalidOrganization:
            "That is not a valid GitHub organization name."
        case .alreadyRegistered:
            "A GitHub App is already registered. Remove it before you create another."
        case .stateMismatch:
            "The GitHub response did not match this session. Create the App again from this page."
        case .missingCode:
            "GitHub returned no code. Create the App again from this page."
        case .conversionFailed:
            "GitHub did not return the App credentials. Create the App again."
        case .secretsNotWritten:
            "The App credentials could not be saved on the server. Check that the working directory is writable."
        }
    }
}
