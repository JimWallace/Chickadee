// APIServer/Routes/Web/GitHubSubmissionRoutes.swift
//
// Submitting a commit from a student-owned GitHub repository
// (docs/github-submissions.md slice 3). Any signed-in, enrolled user. Every
// route is 404 until an admin registers the GitHub App and the assignment
// turns GitHub submission on.
//
//   GET  /testsetups/:id/github  → choose a repository and a branch
//   POST /testsetups/:id/github  → submit the commit the page showed
//   GET  /github/installed       → GitHub returns here after an install
//   POST /testsetups/:id/github/repository
//                                → course-repository mode (slice 4): make the
//                                  student's repository, or invite them again
//
// The page resolves the branch to a SHA and the form posts that SHA, so the
// student submits exactly the commit they saw, even if they push again. The
// POST runs the same open-assignment gate as the upload form before it reads
// anything from GitHub, and saves through the same helper.

import Core
import Fluent
import Foundation
import Vapor

struct GitHubSubmissionRoutes: RouteCollection {
    /// Where `/github/installed` sends the student back to.
    static let returnPathKey = "githubReturnPath"

    func boot(routes: RoutesBuilder) throws {
        routes.get("testsetups", ":testSetupID", "github", use: page)
        routes.post("testsetups", ":testSetupID", "github", use: submit)
        routes.post("testsetups", ":testSetupID", "github", "repository", use: makeRepository)
        routes.get("github", "installed", use: installed)
    }

    // MARK: - GET /testsetups/:id/github

    @Sendable
    func page(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        let setup = try await Self.offeredSetup(req: req, user: user)
        let setupID = try setup.requireID()
        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        // A missing link or installation is shown by the page state itself,
        // so its banner would say the same thing twice.
        let queryError = req.query[String.self, at: "error"].flatMap(GitHubSubmitError.init(rawValue:))
        var state = GitHubSubmitState(
            errorText: [.notLinked, .notInstalled, .noCourseRepository].contains(queryError)
                ? nil : queryError?.message)
        if req.query[String.self, at: "ok"] == "repository" {
            state.noticeText = "Your course repository is ready. Accept the invitation on GitHub."
        }
        do {
            let access = try await Self.access(userID: userID, setup: setup, state: &state, req: req)
            try await state.load(
                access: access,
                repositoryID: req.query[Int64.self, at: "repo"],
                branch: req.query[String.self, at: "branch"],
                configureURL: try await Self.installURL(on: req.db),
                req: req)
        } catch let error as GitHubSubmitError {
            switch error {
            case .notLinked:
                state.needsLink = true
            case .notInstalled:
                state.installURL = try await Self.installURL(on: req.db)
                req.session.data[Self.returnPathKey] = "/testsetups/\(setupID)/github"
            case .noCourseRepository:
                state.canMakeCourseRepository = true
            default:
                state.errorText = error.message
            }
        }
        return try await req.view.render(
            "github-submit",
            GitHubSubmitContext(
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                chips: try await SubmitChips.make(
                    setupID: setupID, assignment: assignment, user: user, on: req.db),
                state: state,
                currentUser: req.currentUserContext,
                flashSuccess: state.noticeText))
    }

    // MARK: - POST /testsetups/:id/github

    struct SubmitBody: Content {
        let repositoryID: Int64
        let sha: String
        /// Only for the way back to the page after an error.
        let branch: String?
    }

    @Sendable
    func submit(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        let setup = try await Self.offeredSetup(req: req, user: user)
        let setupID = try setup.requireID()
        // The deadline is the time this request arrived, checked before any
        // GitHub call so a slow download cannot move it.
        _ = try await requireOpenStudentAssignment(for: setupID, user: user, gate: .submission, on: req)
        let body = try req.content.decode(SubmitBody.self)
        let sha = body.sha.lowercased()
        var page = URLComponents()
        page.path = "/testsetups/\(setupID)/github"
        page.queryItems =
            [URLQueryItem(name: "repo", value: String(body.repositoryID))]
            + (body.branch.map { [URLQueryItem(name: "branch", value: $0)] } ?? [])
        do {
            guard GitHubCommitSHA.isWellFormed(sha) else { throw GitHubSubmitError.commitNotFound }
            var ignored = GitHubSubmitState()
            let access = try await Self.access(userID: userID, setup: setup, state: &ignored, req: req)
            let repository = try await access.ownedRepository(id: body.repositoryID, req: req)
            let tarball = try await access.tarball(of: repository, sha: sha, req: req)
            let subID = freshShortID(prefix: "sub")
            let zipPath = req.application.submissionsDirectory + "\(subID).zip"
            do {
                try await GitHubTarball.writeZip(fromGzippedTar: tarball, to: zipPath)
            } catch {
                try? FileManager.default.removeItem(atPath: zipPath)
                guard let error = error as? GitHubSubmitError else {
                    req.logger.warning("GitHub tarball not converted", metadata: ["error": "\(error)"])
                    throw GitHubSubmitError.unreadable
                }
                throw error
            }
            let submission = APISubmission(
                id: subID, testSetupID: setupID, zipPath: zipPath, attemptNumber: 0,
                userID: userID, kind: APISubmission.Kind.student)
            submission.sourceKind = SubmissionSource.github.rawValue
            submission.sourceRepoID = repository.id
            submission.sourceRepoName = repository.fullName
            submission.sourceCommit = sha
            try await recordStudentSubmission(submission, setup: setup, user: user, req: req)
            req.logger.info(
                "GitHub submission saved",
                metadata: ["submission": "\(subID)", "repository_id": "\(repository.id)", "commit": "\(sha)"])
            return req.redirect(to: "/submissions/\(subID)")
        } catch let error as GitHubSubmitError {
            page.queryItems?.append(URLQueryItem(name: "error", value: error.rawValue))
            return req.redirect(to: page.string ?? "/testsetups/\(setupID)/github")
        }
    }

    // MARK: - POST /testsetups/:id/github/repository

    /// Makes the student's course repository from the assignment's template
    /// and invites them, or sends the invitation again when the first one
    /// failed. A button, not a page load: a GET must not make a repository,
    /// and GitHub limits how fast an App may make them.
    @Sendable
    func makeRepository(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        let setup = try await Self.offeredSetup(req: req, user: user)
        let setupID = try setup.requireID()
        let assignment = try await requireOpenStudentAssignment(for: setupID, user: user, gate: .access, on: req)
        let pagePath = "/testsetups/\(setupID)/github"
        do {
            guard
                let template = try await APIGitHubAssignmentTemplate.query(on: req.db)
                    .filter(\.$testSetupID == setupID).first()
            else { throw GitHubSubmitError.unavailable }
            guard
                let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first()
            else { throw GitHubSubmitError.notLinked }
            let organization = try await GitHubCourseAccess.resolve(courseID: setup.courseID, req: req)
            let login = try await organization.currentLogin(of: link, req: req)
            if let existing = try await APIGitHubCourseRepository.query(on: req.db)
                .filter(\.$testSetupID == setupID).filter(\.$userID == userID).first()
            {
                // A failed invitation is sent again, and an invitation that
                // went to another account than the one linked now is moved
                // to it (#2208).
                try await organization.inviteLinkedAccount(existing, link: link, req: req)
            } else {
                let name = GitHubCourseRepositoryName.make(
                    assignmentSlug: assignment?.slug ?? setupID, login: login)
                let row = try await organization.makeRepository(
                    template: template, name: name, testSetupID: setupID, link: link,
                    login: login, req: req)
                await AuditLogger.record(
                    action: .githubCourseRepositoryCreated, targetType: .user, targetID: userID.uuidString,
                    metadata: ["repository_id": String(row.repoID), "test_setup_id": setupID], on: req)
            }
            return req.redirect(to: pagePath + "?ok=repository")
        } catch let error as GitHubSubmitError {
            return req.redirect(to: pagePath + "?error=\(error.rawValue)")
        }
    }

    // MARK: - GET /github/installed

    /// GitHub sends the student here after they install the App (the setup URL
    /// in the slice-1 manifest). Back to the page they came from, or to the
    /// account page. Only a path this server set is followed.
    @Sendable
    func installed(req: Request) async throws -> Response {
        _ = try req.auth.require(APIUser.self)
        let path = req.session.data[Self.returnPathKey]
        req.session.data[Self.returnPathKey] = nil
        guard let path, path.hasPrefix("/testsetups/"), !path.contains("//") else {
            return req.redirect(to: "/account")
        }
        return req.redirect(to: path)
    }

    // MARK: - Helpers

    /// The test setup, when this caller may submit it from GitHub: enrolled,
    /// an App registered, the assignment opted in, and graded on the worker.
    /// Anything else is 404, so no GitHub route answers until all are true.
    private static func offeredSetup(req: Request, user: APIUser) async throws -> APITestSetup {
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }
        try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
        guard try await GitHubSubmissionOffer.isOffered(setup: setup, on: req.db) else {
            throw Abort(.notFound)
        }
        return setup
    }

    /// The access for this assignment: the student's course repository when
    /// the assignment has a template (slice 4), else the repositories the
    /// student owns (slice 3). Fills in the course-repository view on `state`.
    private static func access(
        userID: UUID, setup: APITestSetup, state: inout GitHubSubmitState, req: Request
    ) async throws -> GitHubSubmissionAccess {
        let setupID = try setup.requireID()
        guard
            try await APIGitHubAssignmentTemplate.query(on: req.db).filter(\.$testSetupID == setupID).first()
                != nil
        else { return try await GitHubSubmissionAccess.resolve(userID: userID, req: req) }
        state.courseRepositoryMode = true
        if let row = try await APIGitHubCourseRepository.query(on: req.db)
            .filter(\.$testSetupID == setupID).filter(\.$userID == userID).first()
        {
            state.courseRepository = GitHubCourseRepositoryView(
                name: row.repoFullName, url: "https://github.com/\(row.repoFullName)", invited: row.invited)
        }
        return try await GitHubSubmissionAccess.resolveCourseRepository(
            userID: userID, testSetupID: setupID, courseID: setup.courseID, req: req)
    }

    private static func installURL(on db: Database) async throws -> String? {
        try await APIGitHubApp.query(on: db).first().map(GitHubSubmissionAccess.installURL(for:))
    }
}

/// A full 40-character hexadecimal commit SHA.
enum GitHubCommitSHA {
    static func isWellFormed(_ sha: String) -> Bool {
        sha.count == 40 && sha.allSatisfy(\.isHexDigit)
    }
}

/// Whether an assignment offers GitHub submission. One predicate, so the
/// submit page link and the routes cannot disagree.
enum GitHubSubmissionOffer {
    static func isOffered(manifest: TestProperties?) -> Bool {
        guard let manifest else { return false }
        return manifest.githubSubmission && manifest.effectiveGradingMode == .worker
    }

    static func isOffered(setup: APITestSetup, on db: Database) async throws -> Bool {
        guard isOffered(manifest: setup.decodedManifest()) else { return false }
        return try await APIGitHubApp.query(on: db).count() > 0
    }
}
