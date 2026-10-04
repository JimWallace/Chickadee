// APIServer/Routes/Web/GitHubSubmitContext.swift
//
// The view model of the GitHub submit page (docs/github-submissions.md
// slice 3) and the steps that fill it: the repositories the linked account
// owns, the branches of the chosen one, and that branch's head commit.

import Fluent
import Foundation
import Vapor

/// The attempt and deadline chips on the upload form and the GitHub submit
/// page, so the two show the same facts.
struct SubmitChips: Encodable {
    /// Prior submissions plus one.
    let attemptNumber: Int
    let deadlineText: String?
    let deadlineISO: String?

    static func make(
        setupID: String, assignment: APIAssignment?, user: APIUser, on db: Database
    ) async throws -> SubmitChips {
        // The deadline actually in force for this student: a personal extension
        // outranks the class due date, which is what the chip must show.
        let extensionDueAt: Date? =
            if let assignment {
                try await studentExtensionDueAt(for: assignment, user: user, on: db)
            } else { nil }
        let deadline = laterDeadline(baseline: assignment?.dueAt, extensionDueAt: extensionDueAt)
        let priorAttempts: Int =
            if let userID = user.id {
                try await APISubmission.query(on: db)
                    .filter(\.$testSetupID == setupID)
                    .filter(\.$userID == userID)
                    .count()
            } else { 0 }
        return SubmitChips(
            attemptNumber: priorAttempts + 1,
            deadlineText: deadline.map { waterlooDateTimeFormatter().string(from: $0) },
            deadlineISO: deadline.map(iso8601String))
    }
}

struct GitHubSubmitCommitView: Encodable, Equatable {
    let repositoryID: String
    let repositoryName: String
    /// Posted back, so an error returns the page to the same branch.
    let branch: String
    let sha: String
    let shortSHA: String
    /// The first line of the commit message, shortened.
    let summary: String
    let commitURL: String
}

/// The student's course repository (slice 4).
struct GitHubCourseRepositoryView: Encodable, Equatable {
    let name: String
    let url: String
    /// False when the invitation failed and can be sent again.
    let invited: Bool
}

struct GitHubSubmitState: Encodable {
    /// The longest commit summary the page shows.
    static let summaryLimit = 72

    var errorText: String?
    var noticeText: String?
    /// The assignment has a template: the student submits only from the
    /// course repository made for them (slice 4).
    var courseRepositoryMode = false
    /// The student's course repository, once made.
    var courseRepository: GitHubCourseRepositoryView?
    /// Course-repository mode and no repository yet: offer to make one.
    var canMakeCourseRepository = false
    /// The student has no linked GitHub account.
    var needsLink = false
    /// The App is not installed on the student's account: where to install it.
    var installURL: String?
    /// The student's installation is readable. The lists below are filled.
    var loaded = false
    /// Where the student changes which repositories the App can read.
    var configureURL: String?
    var repositories: [SelectOption] = []
    var branches: [SelectOption] = []
    var commit: GitHubSubmitCommitView?

    /// Fills the lists. A repository is selected when the query names one of
    /// the student's own, or when there is only one. The branch is the one the
    /// query names, else the default branch.
    mutating func load(
        access: GitHubSubmissionAccess, repositoryID: Int64?, branch requestedBranch: String?,
        configureURL: String?, req: Request
    ) async throws {
        self.configureURL = configureURL
        let owned = try await access.ownedRepositories(req: req)
        loaded = true
        let selected =
            repositoryID.flatMap { id in owned.first { $0.id == id } }
            ?? (owned.count == 1 ? owned.first : nil)
        repositories = owned.map {
            SelectOption(value: String($0.id), label: $0.fullName, selected: $0.id == selected?.id)
        }
        guard let selected else { return }

        let names = try await access.branches(of: selected, req: req)
        let branch =
            requestedBranch.flatMap { names.contains($0) ? $0 : nil }
            ?? (names.contains(selected.defaultBranch) ? selected.defaultBranch : names.first)
        branches = names.map { SelectOption(value: $0, label: $0, selected: $0 == branch) }
        guard let branch else { return }

        let head = try await access.commit(branch, in: selected, req: req)
        commit = GitHubSubmitCommitView(
            repositoryID: String(selected.id),
            repositoryName: selected.fullName,
            branch: branch,
            sha: head.sha,
            shortSHA: String(head.sha.prefix(7)),
            summary: Self.summary(of: head.message),
            commitURL: GitHubSourceLink.commitURL(repositoryName: selected.fullName, sha: head.sha))
    }

    static func summary(of message: String) -> String {
        let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard firstLine.count > summaryLimit else { return firstLine }
        return String(firstLine.prefix(summaryLimit - 1)) + "…"
    }
}

struct GitHubSubmitContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let chips: SubmitChips
    let state: GitHubSubmitState
    let currentUser: CurrentUserContext?
    /// Rendered by the `_flash` partial in `base`.
    let flashSuccess: String?
}

/// The link from a submission to the commit it was made from.
enum GitHubSourceLink {
    static func commitURL(repositoryName: String, sha: String) -> String {
        "https://github.com/\(GitHubRepoClient.repoPath(repositoryName))/commit/\(sha)"
    }
}
