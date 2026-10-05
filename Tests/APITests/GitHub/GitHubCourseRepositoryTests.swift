// Tests/APITests/GitHub/GitHubCourseRepositoryTests.swift
//
// Course repositories (docs/github-submissions.md slice 4): the course page is
// 404 with no App; binding an organization needs the App installed on it and
// the instructor to be an owner, and revokes the user token either way; a TA
// cannot bind; only a granted template can be chosen; a student makes their
// own private repository from the template, is invited to it, and can then
// submit only from it; a failed invitation can be sent again without a second
// repository; archiving archives every course repository. GitHub is faked.

import ChickadeeTestSupport
import CryptoExtras
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubCourseRepositoryTests {
    static let orgID: Int64 = 7_000
    static let studentGitHubID: Int64 = 9_001
    static let sha = "0123abc" + String(repeating: "d", count: 33)
    static let template = GitHubRepository(
        id: 300, fullName: "cs101-org/lab-template", ownerID: orgID, defaultBranch: "main")
    static let made = GitHubRepository(
        id: 400, fullName: "cs101-org/lab-1-octo-student", ownerID: orgID, defaultBranch: "main")
    static let studentOwned = GitHubRepository(
        id: 100, fullName: "octo-student/lab1", ownerID: studentGitHubID, defaultBranch: "main")
    static let manifest = """
        {"schemaVersion":1,"githubSubmission":true,"submissionMode":"uploadOnly","testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()

    let app: Application
    let directory: URL
    /// What the fake GitHub saw.
    let calls = NIOLockedValueBox<[String]>([])
    let revoked = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-course")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-course-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        app.middleware.use(SecurityHeadersMiddleware())
        app.securityConfiguration = AppSecurityConfiguration(
            publicBaseURL: URL(string: "https://courses.example.edu"), enforceHTTPS: false,
            trustForwardedProto: true, sessionCookieSecure: false,
            sessionIdleTimeoutSeconds: 30 * 60, sessionIdleWarningSeconds: 120)
        useOAuth()
        useRepos()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fakes

    /// The instructor's GitHub view: which installations they reach and their
    /// role in `cs101-org`.
    private func useOAuth(installedOnOrganization: Bool = true, role: String? = "admin") {
        let revoked = revoked
        app.githubOAuthClient = GitHubOAuthClient(
            exchangeCode: { exchange in "user-token-\(exchange.code)" },
            fetchUser: { _ in GitHubUser(id: 1, login: "prof") },
            revokeToken: { token, _, _ in revoked.withLockedValue { $0.append(token) } },
            userInstallations: { _ in
                installedOnOrganization
                    ? [
                        GitHubUserInstallation(
                            installationID: 55, accountID: Self.orgID, accountLogin: "cs101-org",
                            accountType: "Organization")
                    ]
                    : [
                        GitHubUserInstallation(
                            installationID: 56, accountID: 1, accountLogin: "prof", accountType: "User")
                    ]
            },
            organizationRole: { _, org in org == "cs101-org" ? role : nil })
    }

    /// `studentLogin` is the login GitHub reports now for the student's
    /// numeric ID; nil means no account has the ID.
    private func useRepos(
        inviteFails: Bool = false, forksAllowed: Bool? = false, studentLogin: String? = "octo-student"
    ) {
        let calls = calls
        let visible = [Self.template, Self.made, Self.studentOwned]
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, _ in GitHubInstallation(id: 5, accountID: Self.studentGitHubID) },
            createInstallationToken: { _, id in
                calls.withLockedValue { $0.append("token:\(id)") }
                return GitHubInstallationToken(token: "installation-\(id)", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in visible },
            repository: { _, id in visible.first { $0.id == id } },
            branches: { _, _ in ["main"] },
            commit: { _, _, _ in GitHubCommit(sha: Self.sha, message: "Start") },
            tarball: { _, fullName, _, _ in
                calls.withLockedValue { $0.append("tarball:\(fullName)") }
                return try await GitHubTarballFixture.make(files: ["main.py": "print(1)\n"])
            },
            templates: { token in
                calls.withLockedValue { $0.append("templates:\(token)") }
                return [Self.template]
            },
            generate: { token, template, owner, name in
                calls.withLockedValue { $0.append("generate:\(token):\(template):\(owner)/\(name)") }
                return Self.made
            },
            userLogin: { _, id in
                calls.withLockedValue { $0.append("user:\(id)") }
                return id == Self.studentGitHubID ? studentLogin : nil
            },
            addCollaborator: { _, fullName, login in
                calls.withLockedValue { $0.append("invite:\(fullName):\(login)") }
                if inviteFails { throw GitHubSubmitError.githubFailed }
            },
            privateForksAllowed: { _, _ in forksAllowed },
            archive: { _, fullName in calls.withLockedValue { $0.append("archive:\(fullName)") } })
    }

    private func seen(_ prefix: String) -> [String] {
        calls.withLockedValue { $0 }.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Fixtures

    private func registerApp() async throws {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "client-secret", webhookSecret: nil, pem: Self.privateKeyPEM,
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: Self.privateKeyPEM, clientSecret: "client-secret", webhookSecret: nil)
            .write(path: app.githubAppSecretsFilePath)
    }

    private func course() async throws -> UUID {
        try await wrMakeCourse(on: app).requireID()
    }

    private func instructor() async throws -> String {
        let cookie = try await wrLoginAsInstructor(on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(user, on: app)
        return cookie
    }

    private func bindOrganization() async throws {
        try await APIGitHubCourseOrganization(
            courseID: try await course(), installationID: 55, orgID: Self.orgID, orgLogin: "cs101-org"
        ).save(on: app.db)
    }

    /// An opted-in assignment with the template, and a linked, enrolled student.
    private func studentWithTemplate(dueAt: Date? = nil) async throws -> String {
        try await wrInsertSetup(id: "gh_setup", manifest: Self.manifest, on: app)
        try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: true, dueAt: dueAt, on: app)
        try await APIGitHubAssignmentTemplate(
            testSetupID: "gh_setup", templateRepoID: Self.template.id, templateFullName: Self.template.fullName
        ).save(on: app.db)
        let cookie = try await loginUser(username: "gh_student", password: "testpassword", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
        try await wrEnrollUser(user, on: app)
        try await APIGitHubAccountLink(
            userID: try user.requireID(), githubUserID: Self.studentGitHubID, githubLogin: "octo-student"
        ).save(on: app.db)
        return cookie
    }

    private func get(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    )
        async throws
    {
        try await app.asyncTest(
            .GET, path, beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: check)
    }

    /// POSTs with a CSRF token; returns the cookie the response set, if any.
    @discardableResult
    private func post(
        _ path: String, form: [String: String] = [:], cookie: String,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws -> String {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var next = bound
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(form.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                if let set = res.headers.first(name: .setCookie) { next = set }
                try check(res)
            })
        return next
    }

    /// Starts a bind and returns the `state` sent to GitHub and the cookie.
    private func startBind(cookie: String) async throws -> (state: String, cookie: String) {
        let location = NIOLockedValueBox("")
        let form = ["organization": "cs101-org"]
        let next = try await post("/instructor/github/bind", form: form, cookie: cookie) { res in
            location.withLockedValue { $0 = res.headers.first(name: .location) ?? "" }
        }
        let authorize = location.withLockedValue { $0 }
        #expect(authorize.hasPrefix("https://github.com/login/oauth/authorize?"))
        let state = try #require(URLComponents(string: authorize)?.queryItems?.first { $0.name == "state" }?.value)
        return (state, next)
    }

    // MARK: - The course page

    @Test func withNoAppTheCoursePageIs404() async throws {
        try await withApp(app) { _ in
            let cookie = try await instructor()
            try await get("/instructor/github", cookie: cookie) { res in #expect(res.status == .notFound) }
        }
    }

    @Test func anUnboundCourseOffersTheInstallAndTheBinding() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await instructor()
            try await get("/instructor/github", cookie: cookie) { res in
                let body = res.body.string
                #expect(res.status == .ok)
                #expect(body.contains("https://github.com/apps/chickadee-courses/installations/new"))
                #expect(body.contains("action=\"/instructor/github/bind\""))
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(csp.contains("form-action 'self' https://github.com"))
            }
        }
    }

    // MARK: - Binding

    @Test func anOwnerBindsTheOrganizationAndTheTokenIsRevoked() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let (state, cookie) = try await startBind(cookie: try await instructor())
            try await get("/github/link/callback?code=abc123&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/github?ok=bound")
            }
            let binding = try #require(try await APIGitHubCourseOrganization.query(on: app.db).first())
            #expect(binding.courseID == (try await course()))
            #expect(binding.installationID == 55)
            #expect(binding.orgID == Self.orgID)
            #expect(revoked.withLockedValue { $0 } == ["user-token-abc123"])
            #expect(try await APIGitHubAccountLink.query(on: app.db).count() == 0, "binding links no account")
            let audits = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.githubCourseBound.rawValue).count()
            #expect(audits == 1)
        }
    }

    @Test func aMemberWhoIsNotAnOwnerCannotBind() async throws {
        useOAuth(role: "member")
        try await withApp(app) { app in
            try await registerApp()
            let (state, cookie) = try await startBind(cookie: try await instructor())
            try await get("/github/link/callback?code=abc123&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.contains("error=notOwner") == true)
            }
            #expect(try await APIGitHubCourseOrganization.query(on: app.db).count() == 0)
            #expect(revoked.withLockedValue { $0 } == ["user-token-abc123"])
        }
    }

    @Test func anOrganizationWithoutTheAppCannotBeBound() async throws {
        useOAuth(installedOnOrganization: false)
        try await withApp(app) { app in
            try await registerApp()
            let (state, cookie) = try await startBind(cookie: try await instructor())
            try await get("/github/link/callback?code=abc123&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.contains("error=notInstalled") == true)
            }
            #expect(try await APIGitHubCourseOrganization.query(on: app.db).count() == 0)
        }
    }

    @Test func aTACannotBind() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let cookie = try await loginUser(username: "gh_ta", password: "testpassword", role: "user", on: app)
            let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_ta").first())
            try await APICourseEnrollment(userID: try user.requireID(), courseID: try await course(), role: .ta)
                .save(on: app.db)
            try await post("/instructor/github/bind", form: ["organization": "cs101-org"], cookie: cookie) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func aStaleBindingDoesNotCaptureAnAccountLink() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let (_, cookie) = try await startBind(cookie: try await instructor())
            // A callback whose state is not the binding's goes to account linking.
            try await get("/github/link/callback?code=abc123&state=other", cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasPrefix("/account") == true)
            }
        }
    }

    // MARK: - Templates and the fork setting

    @Test func onlyAGrantedTemplateCanBeChosen() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let cookie = try await instructor()
            try await bindOrganization()
            try await wrInsertSetup(id: "gh_setup", manifest: Self.manifest, on: app)
            try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: false, on: app)

            try await get("/instructor/github", cookie: cookie) { res in
                #expect(res.body.string.contains("cs101-org/lab-template"))
            }
            try await post(
                "/instructor/github/templates", form: ["testSetupID": "gh_setup", "templateID": "999"], cookie: cookie
            ) { res in #expect(res.headers.first(name: .location)?.contains("error=unknownTemplate") == true) }
            #expect(try await APIGitHubAssignmentTemplate.query(on: app.db).count() == 0)

            try await post(
                "/instructor/github/templates", form: ["testSetupID": "gh_setup", "templateID": "300"], cookie: cookie
            ) { res in #expect(res.headers.first(name: .location) == "/instructor/github?ok=template") }
            let saved = try #require(try await APIGitHubAssignmentTemplate.query(on: app.db).first())
            #expect(saved.templateFullName == "cs101-org/lab-template")

            try await post(
                "/instructor/github/templates", form: ["testSetupID": "gh_setup", "templateID": ""], cookie: cookie
            ) { _ in }
            #expect(try await APIGitHubAssignmentTemplate.query(on: app.db).count() == 0)
        }
    }

    /// Once a student has a repository from the template, the template can
    /// be neither cleared nor changed; choosing it again is fine (#1767).
    @Test func aTemplateWithRepositoriesCannotBeClearedOrChanged() async throws {
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            _ = try await studentWithTemplate()
            let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            try await APIGitHubCourseRepository(
                testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.made.id,
                repoFullName: Self.made.fullName, invited: true
            ).save(on: app.db)
            let cookie = try await instructor()

            try await post(
                "/instructor/github/templates", form: ["testSetupID": "gh_setup", "templateID": ""], cookie: cookie
            ) { res in #expect(res.headers.first(name: .location)?.contains("error=templateInUse") == true) }
            try await post(
                "/instructor/github/templates", form: ["testSetupID": "gh_setup", "templateID": "301"], cookie: cookie
            ) { res in #expect(res.headers.first(name: .location)?.contains("error=templateInUse") == true) }
            let kept = try #require(try await APIGitHubAssignmentTemplate.query(on: app.db).first())
            #expect(kept.templateRepoID == Self.template.id)

            try await post(
                "/instructor/github/templates", form: ["testSetupID": "gh_setup", "templateID": "300"], cookie: cookie
            ) { res in #expect(res.headers.first(name: .location) == "/instructor/github?ok=template") }
            try await get("/instructor/github?error=templateInUse", cookie: cookie) { res in
                #expect(res.body.string.contains(GitHubCourseBindError.templateInUse.message))
            }
        }
    }

    /// The instructor's GitHub view when the App is also on `other-org`,
    /// which they own.
    private func useOAuthWithOtherOrganization() {
        let revoked = revoked
        app.githubOAuthClient = GitHubOAuthClient(
            exchangeCode: { exchange in "user-token-\(exchange.code)" },
            fetchUser: { _ in GitHubUser(id: 1, login: "prof") },
            revokeToken: { token, _, _ in revoked.withLockedValue { $0.append(token) } },
            userInstallations: { _ in
                [
                    GitHubUserInstallation(
                        installationID: 55, accountID: Self.orgID, accountLogin: "cs101-org",
                        accountType: "Organization"),
                    GitHubUserInstallation(
                        installationID: 66, accountID: 8_000, accountLogin: "other-org", accountType: "Organization"),
                ]
            },
            organizationRole: { _, _ in "admin" })
    }

    /// Binds `organization` through the routes and returns where the
    /// callback sent the instructor.
    private func bind(_ organization: String, cookie: String) async throws -> String {
        let location = NIOLockedValueBox("")
        let form = ["organization": organization]
        let next = try await post("/instructor/github/bind", form: form, cookie: cookie) { res in
            location.withLockedValue { $0 = res.headers.first(name: .location) ?? "" }
        }
        let authorize = location.withLockedValue { $0 }
        let state = try #require(URLComponents(string: authorize)?.queryItems?.first { $0.name == "state" }?.value)
        let result = NIOLockedValueBox("")
        try await get("/github/link/callback?code=abc123&state=\(state)", cookie: next) { res in
            result.withLockedValue { $0 = res.headers.first(name: .location) ?? "" }
        }
        return result.withLockedValue { $0 }
    }

    /// One student's course repository in `cs101-org`.
    private func madeRepository() async throws {
        _ = try await studentWithTemplate()
        let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
        try await APIGitHubCourseRepository(
            testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.made.id,
            repoFullName: Self.made.fullName, invited: true
        ).save(on: app.db)
    }

    /// A course with repositories stays bound to the organization they live
    /// in; the same organization binds again (#2207).
    @Test func aCourseWithRepositoriesCannotMoveToAnotherOrganization() async throws {
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            try await madeRepository()
            useOAuthWithOtherOrganization()
            let cookie = try await instructor()

            #expect(try await bind("other-org", cookie: cookie).contains("error=organizationInUse"))
            #expect(try await APIGitHubCourseOrganization.query(on: app.db).first()?.orgID == Self.orgID)
            #expect(try await bind("cs101-org", cookie: cookie) == "/instructor/github?ok=bound")
        }
    }

    /// After an unbind no organization ID is kept, so the owner in the stored
    /// repository names decides (#2207).
    @Test func anUnboundCourseWithRepositoriesBindsOnlyTheirOrganization() async throws {
        try await withApp(app) { app in
            try await registerApp()
            try await madeRepository()
            useOAuthWithOtherOrganization()
            let cookie = try await instructor()

            #expect(try await bind("other-org", cookie: cookie).contains("error=organizationInUse"))
            #expect(try await APIGitHubCourseOrganization.query(on: app.db).count() == 0)
            #expect(try await bind("cs101-org", cookie: cookie) == "/instructor/github?ok=bound")
            #expect(try await APIGitHubCourseOrganization.query(on: app.db).first()?.orgID == Self.orgID)
        }
    }

    @Test func thePageWarnsWhenPrivateForksAreAllowed() async throws {
        useRepos(forksAllowed: true)
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await instructor()
            try await bindOrganization()
            try await get("/instructor/github", cookie: cookie) { res in
                #expect(res.body.string.contains("can fork private repositories"))
            }
        }
    }

    // MARK: - The student's course repository

    @Test func aStudentMakesTheirRepositoryAndSubmitsOnlyFromIt() async throws {
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            let cookie = try await studentWithTemplate()

            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.body.string.contains("Make my repository"))
                #expect(!res.body.string.contains("octo-student/lab1"), "no student-owned repository is offered")
            }
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/testsetups/gh_setup/github?ok=repository")
            }
            #expect(
                seen("generate:") == ["generate:installation-55:cs101-org/lab-template:cs101-org/lab-1-octo-student"])
            #expect(seen("invite:") == ["invite:cs101-org/lab-1-octo-student:octo-student"])
            let row = try #require(try await APIGitHubCourseRepository.query(on: app.db).first())
            #expect(row.repoID == Self.made.id)
            #expect(row.invited)

            try await get("/testsetups/gh_setup/github?ok=repository", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("Accept the invitation on GitHub"))
                #expect(body.contains("<option value=\"400\" selected>cs101-org/lab-1-octo-student</option>"))
                #expect(!body.contains("octo-student/lab1<"))
            }
            try await post(
                "/testsetups/gh_setup/github",
                form: ["repositoryID": String(Self.studentOwned.id), "sha": Self.sha], cookie: cookie
            ) { res in #expect(res.headers.first(name: .location)?.hasSuffix("error=notOwner") == true) }
            try await post(
                "/testsetups/gh_setup/github", form: ["repositoryID": String(Self.made.id), "sha": Self.sha],
                cookie: cookie
            ) { res in #expect(res.headers.first(name: .location)?.hasPrefix("/submissions/") == true) }
            #expect(seen("tarball:") == ["tarball:cs101-org/lab-1-octo-student"])
            let submission = try #require(try await APISubmission.query(on: app.db).first())
            #expect(submission.sourceRepoID == Self.made.id)
        }
    }

    @Test func aFailedInvitationIsSentAgainWithoutASecondRepository() async throws {
        useRepos(inviteFails: true)
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            let cookie = try await studentWithTemplate()
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasSuffix("error=githubFailed") == true)
            }
            let row = try #require(try await APIGitHubCourseRepository.query(on: app.db).first())
            #expect(!row.invited)
            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.body.string.contains("Resend invitation"))
            }

            useRepos()
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { _ in }
            #expect(seen("generate:").count == 1)
            #expect(try await APIGitHubCourseRepository.query(on: app.db).first()?.invited == true)
        }
    }

    /// A renamed account is named and invited by its current login, read from
    /// the linked numeric ID, and the link stores it. GitHub releases a renamed
    /// login for anyone to take, so the stored one could invite a stranger
    /// (#1766).
    @Test func aRenamedAccountIsInvitedByItsCurrentLogin() async throws {
        useRepos(studentLogin: "octo-renamed")
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            let cookie = try await studentWithTemplate()
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/testsetups/gh_setup/github?ok=repository")
            }
            #expect(seen("user:") == ["user:\(Self.studentGitHubID)"])
            #expect(
                seen("generate:") == ["generate:installation-55:cs101-org/lab-template:cs101-org/lab-1-octo-renamed"])
            #expect(seen("invite:") == ["invite:\(Self.made.fullName):octo-renamed"])
            let link = try #require(try await APIGitHubAccountLink.query(on: app.db).first())
            #expect(link.githubLogin == "octo-renamed")
        }
    }

    /// A resent invitation reads the current login too.
    @Test func aResentInvitationGoesToTheCurrentLogin() async throws {
        useRepos(inviteFails: true)
        try await withApp(app) { _ in
            try await registerApp()
            try await bindOrganization()
            let cookie = try await studentWithTemplate()
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { _ in }

            useRepos(studentLogin: "octo-renamed")
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/testsetups/gh_setup/github?ok=repository")
            }
            #expect(seen("generate:").count == 1)
            #expect(seen("invite:").last == "invite:\(Self.made.fullName):octo-renamed")
        }
    }

    /// Adds the collaborator-removal and login fakes the relink tests need:
    /// `classmateID` is the account the repository was first invited under.
    private func useRemovals(classmateID: Int64) {
        let calls = calls
        app.githubRepoClient.userLogin = { _, id in
            calls.withLockedValue { $0.append("user:\(id)") }
            if id == Self.studentGitHubID { return "octo-student" }
            return id == classmateID ? "classmate" : nil
        }
        app.githubRepoClient.removeCollaborator = { _, fullName, login in
            calls.withLockedValue { $0.append("remove:\(fullName):\(login)") }
        }
    }

    /// The repository was invited under a classmate's account, which the
    /// student linked by mistake. *Make my repository* removes the classmate
    /// first, then invites the account linked now, and records it (#2208).
    @Test func aRepositoryInvitedUnderAnotherAccountMovesToTheLinkedOne() async throws {
        let classmateID: Int64 = 9_999
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            let cookie = try await studentWithTemplate()
            useRemovals(classmateID: classmateID)
            let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            let row = APIGitHubCourseRepository(
                testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.made.id,
                repoFullName: Self.made.fullName, invited: true)
            row.invitedGitHubUserID = classmateID
            try await row.save(on: app.db)

            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/testsetups/gh_setup/github?ok=repository")
            }
            #expect(seen("remove:") == ["remove:\(Self.made.fullName):classmate"])
            #expect(seen("invite:") == ["invite:\(Self.made.fullName):octo-student"])
            let moved = try #require(try await APIGitHubCourseRepository.query(on: app.db).first())
            #expect(moved.invited)
            #expect(moved.invitedGitHubUserID == Self.studentGitHubID)
            #expect(seen("generate:").isEmpty)

            // Asked again, nothing more is sent.
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { _ in }
            #expect(seen("remove:").count == 1)
            #expect(seen("invite:").count == 1)
        }
    }

    /// Linking an account moves every course repository still invited under
    /// another one, without the student asking (#2208).
    @Test func linkingAnAccountMovesTheCollaborator() async throws {
        let classmateID: Int64 = 9_999
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            _ = try await studentWithTemplate()
            useRemovals(classmateID: classmateID)
            let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            let row = APIGitHubCourseRepository(
                testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.made.id,
                repoFullName: Self.made.fullName, invited: true)
            row.invitedGitHubUserID = classmateID
            try await row.save(on: app.db)
            let link = try #require(try await APIGitHubAccountLink.query(on: app.db).first())

            await GitHubCourseAccess.moveCollaborators(
                to: link, req: Request(application: app, on: app.eventLoopGroup.any()))
            #expect(seen("remove:") == ["remove:\(Self.made.fullName):classmate"])
            #expect(seen("invite:") == ["invite:\(Self.made.fullName):octo-student"])
            #expect(
                try await APIGitHubCourseRepository.query(on: app.db).first()?.invitedGitHubUserID
                    == Self.studentGitHubID)
        }
    }

    /// When no GitHub account has the linked ID, nothing is made or sent, and
    /// the page asks the student to link again.
    @Test func aLinkedAccountThatIsGoneGetsNoRepository() async throws {
        useRepos(studentLogin: nil)
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            let cookie = try await studentWithTemplate()
            try await post("/testsetups/gh_setup/github/repository", cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasSuffix("error=linkedAccountGone") == true)
            }
            #expect(seen("generate:").isEmpty)
            #expect(seen("invite:").isEmpty)
            #expect(try await APIGitHubCourseRepository.query(on: app.db).count() == 0)
            try await get("/testsetups/gh_setup/github?error=linkedAccountGone", cookie: cookie) { res in
                #expect(res.body.string.contains("no longer exists"))
            }
        }
    }

    @Test func archivingArchivesEveryCourseRepository() async throws {
        try await withApp(app) { app in
            try await registerApp()
            try await bindOrganization()
            _ = try await studentWithTemplate()
            let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            try await APIGitHubCourseRepository(
                testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.made.id,
                repoFullName: Self.made.fullName, invited: true
            ).save(on: app.db)
            let cookie = try await instructor()
            try await post("/instructor/github/archive", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/github?ok=archived")
            }
            #expect(seen("archive:") == ["archive:cs101-org/lab-1-octo-student"])
            #expect(try await APIGitHubCourseRepository.query(on: app.db).first()?.archivedAt != nil)
        }
    }

    @Test func theDataExportListsTheStudentsCourseRepositories() async throws {
        try await withApp(app) { app in
            _ = try await studentWithTemplate()
            let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            try await APIGitHubCourseRepository(
                testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.made.id,
                repoFullName: Self.made.fullName, invited: true
            ).save(on: app.db)
            let content = try await gatherDataExportContent(for: student, on: app.db)
            #expect(content.profile.githubCourseRepositories?.map(\.repository) == [Self.made.fullName])
        }
    }
}

@Suite struct GitHubCourseRepositoryNameTests {
    @Test(arguments: [
        ("lab-1", "octo-student", "lab-1-octo-student"),
        ("lab 1/α", "octo", "lab-1---octo"),
        ("", "octo", "assignment-octo"),
        ("..", "octo", "..-octo"),
    ])
    func names(slug: String, login: String, expected: String) {
        #expect(GitHubCourseRepositoryName.make(assignmentSlug: slug, login: login) == expected)
    }

    @Test func aLongSlugIsShortenedAndTheLoginKept() {
        let name = GitHubCourseRepositoryName.make(assignmentSlug: String(repeating: "a", count: 200), login: "octo")
        #expect(name.count == GitHubCourseRepositoryName.maxLength)
        #expect(name.hasSuffix("-octo"))
    }

    @Test func courseRepositoryPermissionsAreOptIn() throws {
        let base = URL(string: "https://courses.example.edu")
        let plain = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil))
        #expect(plain.body.defaultPermissions == ["contents": "read", "metadata": "read"])
        let course = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil, courseRepositories: true))
        #expect(
            course.body.defaultPermissions
                == ["contents": "read", "metadata": "read", "administration": "write", "members": "read"])
    }
}
