// APIServer/Routes/Web/GitHubCourseRoutes.swift
//
// Course repositories (docs/github-submissions.md slice 4), on the active
// course. Course staff can read the page; per-course instructors change it.
// Every route is 404 while no GitHub App is registered.
//
//   GET  /instructor/github            → the organization, templates, repositories
//   POST /instructor/github/bind       → confirm on GitHub that the instructor
//                                        owns the organization, then bind it
//   POST /instructor/github/unbind     → remove the binding
//   POST /instructor/github/templates  → set or clear an assignment's template
//   POST /instructor/github/archive    → archive every course repository
//
// Binding proves two things through a GitHub user authorization, whose token
// is revoked at once: the App is installed on the organization, and the
// instructor's GitHub account is one of its owners. Without the second check,
// an instructor could bind another organization's installation of the App by
// typing its name, and make repositories there.

import Fluent
import Foundation
import Vapor

struct GitHubCourseRoutes: RouteCollection {
    static let stateKey = "githubBindState"
    static let verifierKey = "githubBindVerifier"
    static let courseKey = "githubBindCourse"
    static let organizationKey = "githubBindOrganization"

    enum Notice: String {
        case bound, unbound, template, archived

        var message: String {
            switch self {
            case .bound: "GitHub organization bound."
            case .unbound: "GitHub organization unbound."
            case .template: "Template saved."
            case .archived: "Course repositories archived."
            }
        }
    }

    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("instructor", "github")
        r.get(use: page)
        r.post("bind", use: bind)
        r.post("unbind", use: unbind)
        r.post("templates", use: saveTemplate)
        r.post("archive", use: archive)
    }

    // MARK: - GET /instructor/github

    @Sendable
    func page(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let app = try await APIGitHubApp.query(on: req.db).first() else { throw Abort(.notFound) }
        let courseState = try await req.resolveActiveCourse(for: user)
        var course: APICourse?
        if let courseID = courseState.activeCourseUUID {
            course = try await APICourse.find(courseID, on: req.db)
        }
        let canEdit =
            course.map { !$0.isArchived } == true
            && (user.isAdmin || (courseState.active?.role ?? .student) >= .instructor)
        let flashError = req.query[String.self, at: "error"].flatMap(GitHubCourseBindError.init(rawValue:))?.message
        var organization: InstructorGitHubOrganization?
        var rows: [InstructorGitHubAssignmentRow] = []
        var repositories: [InstructorGitHubRepositoryRow] = []
        var templatesUnavailable = false
        if let course, let courseID = course.id {
            if let binding = try await APIGitHubCourseOrganization.query(on: req.db)
                .filter(\.$courseID == courseID).first()
            {
                var templates: [GitHubRepository] = []
                var forks: Bool?
                do {
                    let access = try await GitHubCourseAccess.resolve(courseID: courseID, req: req)
                    templates = try await access.templates(req: req)
                    forks = await access.privateForksAllowed(req: req)
                } catch {
                    templatesUnavailable = true
                }
                organization = InstructorGitHubOrganization(
                    login: binding.orgLogin, url: "https://github.com/\(binding.orgLogin)",
                    forksAllowed: forks == true, forksUnknown: forks == nil)
                rows = try await Self.assignmentRows(courseID: courseID, templates: templates, on: req.db)
                repositories = try await Self.repositoryRows(courseID: courseID, on: req.db)
            }
            if canEdit { SecurityHeadersMiddleware.allowFormAction("https://github.com", on: req) }
        }
        return try await req.view.render(
            "instructor-github",
            InstructorGitHubContext(
                currentUser: try await req.courseAwareUserContext(),
                activeInstructorTab: "github",
                hasActiveCourse: course != nil,
                courseCode: course?.code ?? "",
                canEdit: canEdit,
                organization: organization,
                installURL: GitHubSubmissionAccess.installURL(for: app),
                organizationText: req.query[String.self, at: "org"] ?? "",
                assignments: rows,
                templatesUnavailable: templatesUnavailable,
                repositories: repositories,
                flashSuccess: req.query[String.self, at: "ok"].flatMap(Notice.init(rawValue:))?.message,
                flashError: flashError))
    }

    // MARK: - POST /instructor/github/bind

    @Sendable
    func bind(req: Request) async throws -> Response {
        struct BindBody: Content { let organization: String? }
        let courseID = try await Self.requireInstructorCourse(req)
        let text =
            (try? req.content.decode(BindBody.self))?.organization?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let organization = GitHubOrganizationName(text) else {
            return Self.redirect(req, error: .invalidOrganization, organization: text)
        }
        guard
            let app = try await APIGitHubApp.query(on: req.db).first(),
            let redirectURI = GitHubUserAuthorization.redirectURI(
                publicBaseURL: req.application.securityConfiguration.publicBaseURL)
        else { return Self.redirect(req, error: .unavailable) }
        let authorization = GitHubUserAuthorization.make()
        req.session.data[Self.stateKey] = authorization.state
        req.session.data[Self.verifierKey] = authorization.codeVerifier
        req.session.data[Self.courseKey] = courseID.uuidString
        req.session.data[Self.organizationKey] = organization.value
        return req.redirect(to: authorization.authorizeURL(clientID: app.clientID, redirectURI: redirectURI))
    }

    /// True when the callback answers this session's binding request, so the
    /// shared GitHub callback (`/github/link/callback`) sends the code here.
    /// Matched on the state itself, so an abandoned binding cannot capture a
    /// later account link.
    static func isBinding(_ req: Request) -> Bool {
        guard let state = req.session.data[stateKey] else { return false }
        return req.query[String.self, at: "state"] == state
    }

    /// The second half of `bind`, reached from the shared GitHub callback.
    static func completeBinding(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let expectedState = req.session.data[stateKey]
        let verifier = req.session.data[verifierKey]
        let courseText = req.session.data[courseKey]
        let organizationText = req.session.data[organizationKey]
        for key in [stateKey, verifierKey, courseKey, organizationKey] { req.session.data[key] = nil }
        do {
            guard let expectedState, let verifier, let courseText, let courseID = UUID(uuidString: courseText),
                let organizationText, req.query[String.self, at: "state"] == expectedState
            else { throw GitHubCourseBindError.stateMismatch }
            guard let code = req.query[String.self, at: "code"], GitHubManifestCode.isWellFormed(code) else {
                throw GitHubCourseBindError.cancelled
            }
            try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .instructor, db: req.db)
            let installation = try await confirmOwnership(
                code: code, verifier: verifier, organization: organizationText, req: req)
            try await saveBinding(courseID: courseID, installation: installation, on: req.db)
            await AuditLogger.record(
                action: .githubCourseBound, targetType: .course, targetID: courseID.uuidString,
                metadata: [
                    "organization": installation.accountLogin, "installation_id": String(installation.installationID),
                ],
                on: req)
            return req.redirect(to: "/instructor/github?ok=\(Notice.bound.rawValue)")
        } catch let error as GitHubCourseBindError {
            return redirect(req, error: error, organization: organizationText ?? "")
        }
    }

    /// Exchanges the code, finds the App's installation on the organization,
    /// checks that the user is an active owner of it, and revokes the token.
    private static func confirmOwnership(
        code: String, verifier: String, organization: String, req: Request
    ) async throws -> GitHubUserInstallation {
        guard
            let app = try await APIGitHubApp.query(on: req.db).first(),
            let secrets = try? GitHubAppSecrets.load(path: req.application.githubAppSecretsFilePath),
            let redirectURI = GitHubUserAuthorization.redirectURI(
                publicBaseURL: req.application.securityConfiguration.publicBaseURL)
        else { throw GitHubCourseBindError.unavailable }
        let client = req.application.githubOAuthClient
        let token: String
        do {
            token = try await client.exchangeCode(
                GitHubCodeExchange(
                    clientID: app.clientID, clientSecret: secrets.clientSecret, code: code,
                    codeVerifier: verifier, redirectURI: redirectURI))
        } catch {
            req.logger.warning("GitHub course binding exchange failed", metadata: ["error": "\(error)"])
            throw GitHubCourseBindError.exchangeFailed
        }
        let lookup: Result<([GitHubUserInstallation], String?), any Error>
        do {
            lookup = .success(
                (try await client.userInstallations(token), try await client.organizationRole(token, organization)))
        } catch {
            lookup = .failure(error)
        }
        // Revoked before any answer is used, so no path keeps the token.
        do {
            try await client.revokeToken(token, app.clientID, secrets.clientSecret)
        } catch {
            req.logger.warning("GitHub user token not revoked", metadata: ["error": "\(error)"])
        }
        guard case .success(let (installations, role)) = lookup else {
            req.logger.warning("GitHub course binding check failed")
            throw GitHubCourseBindError.githubFailed
        }
        guard
            let installation = installations.first(where: {
                $0.accountType == "Organization" && $0.accountLogin.lowercased() == organization.lowercased()
            })
        else { throw GitHubCourseBindError.notInstalled }
        guard role == "admin" else { throw GitHubCourseBindError.notOwner }
        return installation
    }

    private static func saveBinding(
        courseID: UUID, installation: GitHubUserInstallation, on db: Database
    ) async throws {
        let row =
            try await APIGitHubCourseOrganization.query(on: db).filter(\.$courseID == courseID).first()
            ?? APIGitHubCourseOrganization(
                courseID: courseID, installationID: installation.installationID,
                orgID: installation.accountID, orgLogin: installation.accountLogin)
        row.installationID = installation.installationID
        row.orgID = installation.accountID
        row.orgLogin = installation.accountLogin
        try await row.save(on: db)
    }

    // MARK: - POST /instructor/github/unbind

    /// Removes the binding. Course repositories and their rows stay, so
    /// grades keep their commits; binding again resumes them.
    @Sendable
    func unbind(req: Request) async throws -> Response {
        let courseID = try await Self.requireInstructorCourse(req)
        try await APIGitHubCourseOrganization.query(on: req.db).filter(\.$courseID == courseID).delete()
        await AuditLogger.record(
            action: .githubCourseUnbound, targetType: .course, targetID: courseID.uuidString, metadata: [:],
            on: req)
        return req.redirect(to: "/instructor/github?ok=\(Notice.unbound.rawValue)")
    }

    // MARK: - POST /instructor/github/templates

    @Sendable
    func saveTemplate(req: Request) async throws -> Response {
        struct TemplateBody: Content {
            let testSetupID: String
            let templateID: String?
        }
        let courseID = try await Self.requireInstructorCourse(req)
        let body = try req.content.decode(TemplateBody.self)
        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db), setup.courseID == courseID
        else { throw Abort(.notFound) }
        let existing = try await APIGitHubAssignmentTemplate.query(on: req.db)
            .filter(\.$testSetupID == body.testSetupID).first()
        let templateID = body.templateID.flatMap { Int64($0) }
        // Clearing or changing the template once repositories exist would
        // give later students a different start, and would send a student
        // whose repository exists to owned-repository mode, which refuses the
        // organization's repository as not theirs (#1767). The same gate as
        // the LTI platform delete: refuse while rows depend on it.
        if let existing, existing.templateRepoID != templateID {
            let made = try await APIGitHubCourseRepository.query(on: req.db)
                .filter(\.$testSetupID == body.testSetupID).count()
            if made > 0 { return Self.redirect(req, error: .templateInUse) }
        }
        if let templateID {
            // Only a template the organization's installation grants.
            let access: GitHubCourseAccess
            let templates: [GitHubRepository]
            do {
                access = try await GitHubCourseAccess.resolve(courseID: courseID, req: req)
                templates = try await access.templates(req: req)
            } catch {
                return Self.redirect(req, error: .githubFailed)
            }
            guard let template = templates.first(where: { $0.id == templateID }) else {
                return Self.redirect(req, error: .unknownTemplate)
            }
            let row =
                existing
                ?? APIGitHubAssignmentTemplate(
                    testSetupID: body.testSetupID, templateRepoID: template.id, templateFullName: template.fullName)
            row.templateRepoID = template.id
            row.templateFullName = template.fullName
            try await row.save(on: req.db)
        } else {
            try await existing?.delete(on: req.db)
        }
        await AuditLogger.record(
            action: .githubTemplateSet, targetType: .assignment, targetID: body.testSetupID,
            metadata: ["template_id": templateID.map(String.init) ?? ""], on: req)
        return req.redirect(to: "/instructor/github?ok=\(Notice.template.rawValue)")
    }

    // MARK: - POST /instructor/github/archive

    /// Archives every course repository of the course that is not archived
    /// yet. They stay on GitHub, read-only, because grades point at their
    /// commits.
    @Sendable
    func archive(req: Request) async throws -> Response {
        let courseID = try await Self.requireInstructorCourse(req)
        let setupIDs = try await APITestSetup.query(on: req.db).filter(\.$courseID == courseID).all()
            .compactMap(\.id)
        let rows = try await APIGitHubCourseRepository.query(on: req.db)
            .filter(\.$testSetupID ~~ setupIDs).filter(\.$archivedAt == nil).all()
        var archived = 0
        do {
            let access = try await GitHubCourseAccess.resolve(courseID: courseID, req: req)
            for row in rows {
                try await access.archive(row, req: req)
                archived += 1
            }
        } catch {
            await Self.auditArchive(courseID: courseID, count: archived, req: req)
            return Self.redirect(req, error: .githubFailed)
        }
        await Self.auditArchive(courseID: courseID, count: archived, req: req)
        return req.redirect(to: "/instructor/github?ok=\(Notice.archived.rawValue)")
    }

    private static func auditArchive(courseID: UUID, count: Int, req: Request) async {
        guard count > 0 else { return }
        await AuditLogger.record(
            action: .githubCourseRepositoriesArchived, targetType: .course, targetID: courseID.uuidString,
            metadata: ["count": String(count)], on: req)
    }

    // MARK: - Helpers

    /// The active course, when the caller is one of its instructors and an
    /// App is registered. Course structure, so the per-course instructor floor.
    private static func requireInstructorCourse(_ req: Request) async throws -> UUID {
        let user = try req.auth.require(APIUser.self)
        guard try await APIGitHubApp.query(on: req.db).count() > 0 else { throw Abort(.notFound) }
        guard let courseID = try await req.resolveActiveCourse(for: user).activeCourseUUID else {
            throw Abort(.badRequest, reason: "No active course.")
        }
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .instructor, db: req.db)
        return courseID
    }

    /// The course's assignments that accept GitHub submission, with their
    /// template choice and how many repositories exist.
    private static func assignmentRows(
        courseID: UUID, templates: [GitHubRepository], on db: Database
    ) async throws -> [InstructorGitHubAssignmentRow] {
        let assignments = try await APIAssignment.query(on: db).filter(\.$courseID == courseID)
            .sort(\.$title).all()
        var rows: [InstructorGitHubAssignmentRow] = []
        for assignment in assignments {
            guard let setup = try await APITestSetup.find(assignment.testSetupID, on: db),
                GitHubSubmissionOffer.isOffered(manifest: setup.decodedManifest())
            else { continue }
            let chosen = try await APIGitHubAssignmentTemplate.query(on: db)
                .filter(\.$testSetupID == assignment.testSetupID).first()
            let count = try await APIGitHubCourseRepository.query(on: db)
                .filter(\.$testSetupID == assignment.testSetupID).count()
            let options =
                [
                    GitHubSubmitOption(
                        value: "", label: "None", selected: chosen == nil)
                ]
                + templates.map {
                    GitHubSubmitOption(
                        value: String($0.id), label: $0.fullName, selected: $0.id == chosen?.templateRepoID)
                }
            rows.append(
                InstructorGitHubAssignmentRow(
                    testSetupID: assignment.testSetupID, title: assignment.title, templateOptions: options,
                    templateName: chosen?.templateFullName, repositoryCount: count))
        }
        return rows
    }

    /// Every course repository of the course, by assignment then student.
    private static func repositoryRows(courseID: UUID, on db: Database) async throws -> [InstructorGitHubRepositoryRow]
    {
        let assignments = try await APIAssignment.query(on: db).filter(\.$courseID == courseID).all()
        let titles = Dictionary(assignments.map { ($0.testSetupID, $0.title) }) { first, _ in first }
        let repositories = try await APIGitHubCourseRepository.query(on: db)
            .filter(\.$testSetupID ~~ Array(titles.keys)).all()
        let users = try await APIUser.query(on: db).filter(\.$id ~~ repositories.map(\.userID)).all()
        var names: [UUID: String] = [:]
        for user in users {
            if let id = user.id {
                names[id] = accountIdentityName(
                    displayName: user.displayName, preferredName: user.preferredName, username: user.username)
            }
        }
        let formatter = waterlooDateTimeFormatter()
        return repositories.map { row in
            InstructorGitHubRepositoryRow(
                assignmentTitle: titles[row.testSetupID] ?? row.testSetupID,
                studentName: names[row.userID] ?? "Unknown student",
                repositoryName: row.repoFullName,
                repositoryURL: "https://github.com/\(row.repoFullName)",
                lastPushedText: row.lastPushedAt.map { formatter.string(from: $0) } ?? "Not reported",
                lastPushedISO: row.lastPushedAt.map(iso8601String),
                archived: row.archivedAt != nil)
        }
        .sorted { ($0.assignmentTitle, $0.studentName) < ($1.assignmentTitle, $1.studentName) }
    }

    private static func redirect(
        _ req: Request, error: GitHubCourseBindError, organization: String = ""
    ) -> Response {
        var components = URLComponents()
        components.path = "/instructor/github"
        components.queryItems =
            [URLQueryItem(name: "error", value: error.rawValue)]
            + (organization.isEmpty ? [] : [URLQueryItem(name: "org", value: organization)])
        return req.redirect(to: components.string ?? "/instructor/github")
    }
}
