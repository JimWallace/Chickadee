// APIServer/GitHub/GitHubSubmitError.swift
//
// Each way that submitting a commit from GitHub can fail, with the sentence
// the GitHub submit page shows. Every sentence that is not the student's to
// fix points to the upload form, which always stays available.

enum GitHubSubmitError: String, Error, Equatable {
    /// No App is registered, its secrets are missing, or the assignment does
    /// not accept GitHub submissions.
    case unavailable
    /// The student has not linked a GitHub account.
    case notLinked
    /// The App is not installed on the student's GitHub account.
    case notInstalled
    /// The installation cannot see the repository.
    case repositoryNotFound
    /// The linked account does not own the repository.
    case notOwner
    /// The branch or commit does not exist.
    case commitNotFound
    /// GitHub did not answer, or its answer could not be read.
    case githubFailed
    /// The commit is larger than the submission size limit.
    case tooLarge
    /// The commit has no files to submit.
    case empty
    /// The tarball could not be read.
    case unreadable
    /// GitHub refused to make a repository because the App makes them too fast.
    case rateLimited
    /// The course organization already has a repository with that name.
    case repositoryNameTaken
    /// The assignment uses course repositories and this student has none yet.
    case noCourseRepository

    var message: String {
        switch self {
        case .unavailable:
            "GitHub submission is not available for this assignment. Use the upload form."
        case .notLinked:
            "Link a GitHub account on your account page first."
        case .notInstalled:
            "Install the GitHub App on your GitHub account, then try again."
        case .repositoryNotFound:
            "That repository is not available. Choose one from the list."
        case .notOwner:
            "You can submit only a repository that your linked GitHub account owns."
        case .commitNotFound:
            "That branch or commit was not found. Choose it again."
        case .githubFailed:
            "GitHub did not respond. Try again later, or use the upload form."
        case .tooLarge:
            "The commit is larger than \(GitHubTarball.maxFileBytes / 1_048_576) MB. "
                + "Remove large files, or use the upload form."
        case .empty:
            "The commit has no files to submit."
        case .unreadable:
            "The files in that commit could not be read. Use the upload form."
        case .rateLimited:
            "GitHub is busy. Try again in a few minutes, or use the upload form."
        case .repositoryNameTaken:
            "The course organization already has a repository with that name. Ask course staff."
        case .noCourseRepository:
            "Make your course repository first."
        }
    }
}
