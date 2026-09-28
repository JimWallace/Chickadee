// APIServer/GitHub/GitHubCourseBindError.swift
//
// Each way that binding a GitHub organization to a course, or using it, can
// fail, with the sentence the course GitHub page shows.

enum GitHubCourseBindError: String, Error, Equatable {
    /// No App is registered, its secrets are missing, or no base URL is set.
    case unavailable
    /// The organization name is not a GitHub login.
    case invalidOrganization
    /// The callback `state` does not match the one this session sent.
    case stateMismatch
    /// The instructor declined on GitHub, or the callback carried no code.
    case cancelled
    /// GitHub refused the code, or its answer could not be read.
    case exchangeFailed
    /// The App is not installed on that organization.
    case notInstalled
    /// The instructor's GitHub account is not an owner of the organization.
    case notOwner
    /// A GitHub call failed while the page was in use.
    case githubFailed
    /// The chosen template is not one the organization's installation grants.
    case unknownTemplate

    var message: String {
        switch self {
        case .unavailable:
            "Course repositories are not available on this server."
        case .invalidOrganization:
            "Type the organization's GitHub login, for example uwaterloo-cs."
        case .stateMismatch:
            "The GitHub response did not match this session. Bind the organization again."
        case .cancelled:
            "GitHub did not confirm the organization. Bind it again when you are ready."
        case .exchangeFailed:
            "GitHub did not confirm your account. Bind the organization again."
        case .notInstalled:
            "The GitHub App is not installed on that organization. Install it, then bind again."
        case .notOwner:
            "Only an owner of the organization can bind it to a course."
        case .githubFailed:
            "GitHub did not respond. Try again later."
        case .unknownTemplate:
            "That template is not available. Mark the repository as a template on GitHub, or give the App access to it."
        }
    }
}
