// Tests/APITests/GitHub/GitHubSubmissionRoutesTests.swift
//
// Submitting a commit from GitHub (docs/github-submissions.md slice 3): the
// routes stay 404 until an App is registered and the assignment opts in; the
// page walks an unlinked or uninstalled student to the next step, lists only
// the repositories the linked account owns, and shows the head commit; the
// POST refuses a classmate's repository, refuses a late submission exactly as
// the upload form does and before any GitHub call, refuses an oversized
// commit, and saves a stripped zip attributed to the caller. GitHub is faked
// throughout; the tarball is a real one.

import ChickadeeTestSupport
import CryptoExtras
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubSubmissionRoutesTests {
    static let githubUserID: Int64 = 9_001
    static let sha = "0123abc" + String(repeating: "d", count: 33)
    static let owned = GitHubRepository(
        id: 100, fullName: "octo-student/lab1", ownerID: githubUserID, defaultBranch: "main")
    static let classmates = GitHubRepository(
        id: 200, fullName: "classmate/lab1", ownerID: 555, defaultBranch: "main")
    static let manifest = """
        {"schemaVersion":1,"githubSubmission":true,"submissionMode":"uploadOnly","testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()

    let app: Application
    let directory: URL
    /// What the fake GitHub saw.
    let tokenRequests = NIOLockedValueBox(0)
    let tarballRequests = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-submit")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-submit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        useGitHub()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Points the app at a fake GitHub. `installation` nil means the App is not
    /// installed; `tarball` is what a download returns.
    private func useGitHub(
        installation: GitHubInstallation? = GitHubInstallation(id: 5, accountID: githubUserID),
        tarball: @escaping @Sendable () async throws -> Data = {
            try await GitHubTarballFixture.make(
                files: ["main.py": "print(1)\n", "src/util.py": "x = 2\n"], symlinks: ["link": "/etc/passwd"])
        }
    ) {
        let tokenRequests = tokenRequests
        let tarballRequests = tarballRequests
        let all = [Self.owned, Self.classmates]
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, login in login == "octo-student" ? installation : nil },
            createInstallationToken: { _, _ in
                tokenRequests.withLockedValue { $0 += 1 }
                return GitHubInstallationToken(token: "installation-token", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in all },
            repository: { _, id in all.first { $0.id == id } },
            branches: { _, _ in ["main", "dev"] },
            commit: { _, _, ref in
                ref == "main" || ref == "dev" ? GitHubCommit(sha: Self.sha, message: "Finish lab 1\n\nDetails") : nil
            },
            tarball: { _, fullName, sha, _ in
                tarballRequests.withLockedValue { $0.append("\(fullName)@\(sha)") }
                return try await tarball()
            })
    }

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

    /// An enrolled student with an open, opted-in assignment. Returns the cookie.
    private func student(
        manifest: String = manifest, dueAt: Date? = nil, linked: Bool = true
    ) async throws -> String {
        let cookie = try await loginUser(username: "gh_student", password: "testpassword", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
        try await wrEnrollUser(user, on: app)
        try await wrInsertSetup(id: "gh_setup", manifest: manifest, on: app)
        try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: true, dueAt: dueAt, on: app)
        if linked {
            try await APIGitHubAccountLink(
                userID: try user.requireID(), githubUserID: Self.githubUserID, githubLogin: "octo-student"
            ).save(on: app.db)
        }
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

    private func submit(
        repositoryID: Int64 = owned.id, sha: String = sha, branch: String = "main", cookie: String,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await post(
            "/testsetups/gh_setup/github",
            form: ["repositoryID": String(repositoryID), "sha": sha, "branch": branch],
            cookie: cookie, check)
    }

    private func post(
        _ path: String, form: [String: String], cookie: String,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(form.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: check)
    }

    private func submissions() async throws -> [APISubmission] {
        try await APISubmission.query(on: app.db).all()
    }

    // MARK: - No App, no change

    @Test func withNoAppTheRouteIs404AndTheSubmitPageHasNoLink() async throws {
        try await withApp(app) { _ in
            let cookie = try await student()
            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.status == .notFound)
            }
            try await get("/testsetups/gh_setup/submit", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("/testsetups/gh_setup/github"))
            }
        }
    }

    @Test func anAssignmentThatHasNotOptedInIs404() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student(manifest: #"{"schemaVersion":1,"submissionMode":"uploadOnly"}"#)
            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.status == .notFound)
            }
            try await submit(cookie: cookie) { res in #expect(res.status == .notFound) }
            #expect(try await submissions().isEmpty)
        }
    }

    @Test func theSubmitPageLinksToGitHubWhenOffered() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await get("/testsetups/gh_setup/submit", cookie: cookie) { res in
                #expect(res.body.string.contains("href=\"/testsetups/gh_setup/github\""))
            }
        }
    }

    // MARK: - The page

    @Test func anUnlinkedStudentIsSentToTheAccountPage() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student(linked: false)
            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("href=\"/account\""))
                #expect(!res.body.string.contains("octo-student/lab1"))
                #expect(res.body.string.contains("Attempt 1"))
            }
            // After a failed POST the page says it once, not in a banner too.
            try await get("/testsetups/gh_setup/github?error=notLinked", cookie: cookie) { res in
                #expect(!res.body.string.contains("role=\"alert\""))
            }
        }
    }

    @Test func aStudentWithoutTheAppIsSentToInstallItAndBroughtBack() async throws {
        useGitHub(installation: nil)
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.body.string.contains("https://github.com/apps/chickadee-courses/installations/new"))
            }
            try await get("/github/installed?installation_id=5&setup_action=install", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/testsetups/gh_setup/github")
            }
            try await get("/github/installed", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account", "the return path is used once")
            }
        }
    }

    @Test func anInstallationOnAnotherAccountIsNotUsed() async throws {
        useGitHub(installation: GitHubInstallation(id: 6, accountID: 1))
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await get("/testsetups/gh_setup/github", cookie: cookie) { res in
                #expect(res.body.string.contains("/installations/new"))
                #expect(!res.body.string.contains("octo-student/lab1"))
            }
            #expect(tokenRequests.withLockedValue { $0 } == 0)
        }
    }

    @Test func thePageListsOnlyOwnedRepositoriesAndShowsTheHeadCommit() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await get("/testsetups/gh_setup/github?repo=100&branch=dev", cookie: cookie) { res in
                let body = res.body.string
                #expect(res.status == .ok)
                #expect(body.contains("octo-student/lab1"))
                #expect(!body.contains("classmate/lab1"))
                #expect(body.contains(#"<option value="dev" selected>"#))
                #expect(body.contains("Submit commit 0123abc"))
                #expect(body.contains("value=\"\(Self.sha)\""))
                #expect(body.contains("Finish lab 1"))
                #expect(!body.contains("Details"))
            }
        }
    }

    @Test func theInstallationTokenIsReusedAcrossRequests() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await get("/testsetups/gh_setup/github", cookie: cookie) { _ in }
            try await get("/testsetups/gh_setup/github?repo=100", cookie: cookie) { _ in }
            #expect(tokenRequests.withLockedValue { $0 } == 1)
        }
    }

    // MARK: - Submitting

    @Test func submittingSavesAStrippedZipForTheCaller() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let cookie = try await student()
            var location = ""
            try await submit(cookie: cookie) { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location) ?? ""
            }
            let saved = try #require(try await submissions().first)
            let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            #expect(location == "/submissions/\(try saved.requireID())")
            #expect(saved.userID == user.id)
            #expect(saved.kind == APISubmission.Kind.student)
            #expect(saved.attemptNumber == 1)
            #expect(saved.sourceKind == SubmissionSource.github.rawValue)
            #expect(saved.sourceRepoID == Self.owned.id)
            #expect(saved.sourceRepoName == "octo-student/lab1")
            #expect(saved.sourceCommit == Self.sha)
            #expect(tarballRequests.withLockedValue { $0 } == ["octo-student/lab1@\(Self.sha)"])
            #expect(Set(await listZipEntries(zipPath: saved.zipPath)) == ["main.py", "src/util.py"])

            try await get(location, cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("From GitHub: octo-student/lab1"))
                #expect(body.contains("https://github.com/octo-student/lab1/commit/\(Self.sha)"))
                #expect(body.contains("<code>0123abc</code>"))
            }
        }
    }

    @Test func aClassmatesRepositoryIsRefused() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await submit(repositoryID: Self.classmates.id, cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasSuffix("error=notOwner") == true)
            }
            #expect(try await submissions().isEmpty)
            #expect(tarballRequests.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func aLateSubmissionIsRefusedLikeAnUploadAndReadsNothing() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student(dueAt: Date().addingTimeInterval(-60))
            try await submit(cookie: cookie) { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("closed"))
            }
            #expect(try await submissions().isEmpty)
            #expect(tarballRequests.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func anOversizedCommitIsRefusedAndThePageKeepsTheBranch() async throws {
        useGitHub(tarball: { throw GitHubSubmitError.tooLarge })
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await submit(branch: "dev", cookie: cookie) { res in
                #expect(
                    res.headers.first(name: .location)
                        == "/testsetups/gh_setup/github?repo=100&branch=dev&error=tooLarge")
            }
            #expect(try await submissions().isEmpty)
            try await get("/testsetups/gh_setup/github?repo=100&error=tooLarge", cookie: cookie) { res in
                #expect(res.body.string.contains(GitHubSubmitError.tooLarge.message))
                #expect(res.body.string.contains("role=\"alert\""))
            }
        }
    }

    @Test func aMalformedSHAIsRefusedBeforeAnyDownload() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let cookie = try await student()
            try await submit(sha: "0123abc", cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasSuffix("error=commitNotFound") == true)
            }
            #expect(tarballRequests.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func aTarballThatIsNotGzipIsRefusedAndLeavesNoFile() async throws {
        useGitHub(tarball: { Data("not a tarball".utf8) })
        try await withApp(app) { app in
            try await registerApp()
            let cookie = try await student()
            try await submit(cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasSuffix("error=unreadable") == true)
            }
            #expect(try await submissions().isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: app.submissionsDirectory)
            #expect(left.isEmpty)
        }
    }

    // MARK: - The instructor setting

    @Test func editPageOffersTheSettingOnlyWithAnApp() async throws {
        try await withApp(app) { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "gh_edit", manifest: Self.manifest, on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "gh_edit", title: "Lab", isOpen: false, on: app)
            let action = "action=\"/instructor/\(assignment.publicID)/github-submission\""
            try await get("/instructor/\(assignment.publicID)/edit", cookie: cookie) { res in
                #expect(!res.body.string.contains(action))
            }
            try await registerApp()
            try await get("/instructor/\(assignment.publicID)/edit", cookie: cookie) { res in
                #expect(res.body.string.contains(action))
            }
        }
    }

    @Test func theSettingIsSavedByItsOwnEndpointAndAudited() async throws {
        try await withApp(app) { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "gh_toggle", manifest: #"{"schemaVersion":1}"#, on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "gh_toggle", title: "Lab", isOpen: true, on: app)
            let path = "/instructor/\(assignment.publicID)/github-submission"

            try await post(path, form: ["enabled": "on"], cookie: cookie) { res in
                #expect(res.status == .seeOther)
            }
            #expect(try await APITestSetup.find("gh_toggle", on: app.db)?.decodedManifest()?.githubSubmission == true)
            let reopened = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reopened.isOpen, "the setting must not close the assignment")

            // An unchecked box is absent from the body.
            try await post(path, form: [:], cookie: cookie) { res in #expect(res.status == .seeOther) }
            #expect(try await APITestSetup.find("gh_toggle", on: app.db)?.decodedManifest()?.githubSubmission == false)

            let audits = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.githubSubmissionToggled.rawValue).count()
            #expect(audits == 2)
        }
    }

    @Test func browserGradedAssignmentsDoNotOfferTheSetting() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(
                id: "gh_browser", manifest: #"{"schemaVersion":1,"gradingMode":"browser"}"#, on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "gh_browser", title: "Lab", isOpen: false, on: app)
            try await get("/instructor/\(assignment.publicID)/edit", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("/github-submission"))
            }
        }
    }

    @Test func settingTheFlagSavesOnlyAChange() async throws {
        try await withApp(app) { app in
            let setup = try await wrInsertSetup(id: "gh_flag", manifest: #"{"schemaVersion":1}"#, on: app)
            try await setManifestGitHubSubmission(setup: setup, enabled: true, on: app.db)
            let on = try #require(try await APITestSetup.find("gh_flag", on: app.db))
            #expect(on.decodedManifest()?.githubSubmission == true)
            try await setManifestGitHubSubmission(setup: on, enabled: false, on: app.db)
            let off = try #require(try await APITestSetup.find("gh_flag", on: app.db))
            #expect(off.decodedManifest()?.githubSubmission == false)
            #expect(!off.manifest.contains("githubSubmission"))
        }
    }
}
