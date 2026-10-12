// Tests/APITests/GitHub/GitHubStarterRepositoryTests.swift
//
// Starter repositories and the private-repository rule
// (docs/github-submissions.md "Starter repositories"): an instructor names a
// public template, which students copy into a private repository of their
// own; the submit page links to it and says when the chosen repository was
// not made from it; and a public repository is refused, on the page and at
// the submit, before any download. GitHub is faked throughout.

import ChickadeeTestSupport
import Core
import CryptoExtras
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite struct GitHubRepositoryNameTests {
    @Test(arguments: [
        ("cs101/lab1-starter", "cs101/lab1-starter"),
        ("  cs101/lab1  ", "cs101/lab1"),
        ("https://github.com/cs101/lab1", "cs101/lab1"),
        ("https://github.com/cs101/lab1/", "cs101/lab1"),
        ("https://github.com/cs101/lab1.git", "cs101/lab1"),
        ("github.com/cs101/lab_1.v2", "cs101/lab_1.v2"),
    ])
    func acceptsANameOrAURL(raw: String, expected: String) {
        #expect(GitHubRepositoryName(raw)?.value == expected)
    }

    @Test(arguments: [
        "", "cs101", "cs101/", "/lab1", "cs101/lab1/tree/main", "-cs101/lab1", "cs101/..", "cs101/.",
        "cs101/lab 1", "https://gitlab.com/cs101/lab1", "cs101/lab1?x=1",
    ])
    func refusesAnythingElse(raw: String) {
        #expect(GitHubRepositoryName(raw) == nil)
    }

    @Test func theURLIsTheRepositoryPage() throws {
        let name = try #require(GitHubRepositoryName("cs101/lab1"))
        #expect(name.url == "https://github.com/cs101/lab1")
    }
}

@Suite struct GitHubStarterManifestTests {
    @Test func theStarterIsKeptOnTheServerAndEncodedOnlyWhenSet() throws {
        let decoded = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(#"{"schemaVersion":1,"githubSubmission":true,"githubStarterRepository":"cs101/lab1"}"#.utf8))
        #expect(decoded.githubStarterRepository == "cs101/lab1")
        #expect(decoded.runnerSanitized().githubStarterRepository == nil)
        let bytes = try ManifestCodec.stableEncoder.encode(decoded)
        #expect(try ManifestCodec.decoder.decode(TestProperties.self, from: bytes) == decoded)
        let unset = try #require(
            String(bytes: try ManifestCodec.stableEncoder.encode(TestProperties(language: nil)), encoding: .utf8))
        #expect(!unset.contains("githubStarterRepository"))
    }

    @Test func aRebuildKeepsTheStarter() throws {
        let stored = #"{"schemaVersion":1,"githubSubmission":true,"githubStarterRepository":"cs101/lab1"}"#
        let props = try #require(decodeManifest(fromJSON: stored))
        let rebuilt = try makeWorkerManifestJSON(preserving: props, testSuites: [], language: nil)
        #expect(decodeManifest(fromJSON: rebuilt)?.githubStarterRepository == "cs101/lab1")
    }
}

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubStarterRepositoryTests {
    static let githubUserID: Int64 = 9_001
    static let sha = "0123abc" + String(repeating: "d", count: 33)
    static let copy = GitHubRepository(
        id: 100, fullName: "octo-student/lab1", ownerID: githubUserID, defaultBranch: "main", isPrivate: true,
        templateFullName: "cs101/lab1-starter")
    static let other = GitHubRepository(
        id: 101, fullName: "octo-student/scratch", ownerID: githubUserID, defaultBranch: "main", isPrivate: true)
    static let open = GitHubRepository(
        id: 102, fullName: "octo-student/public-lab1", ownerID: githubUserID, defaultBranch: "main",
        isPrivate: false, templateFullName: "cs101/lab1-starter")
    static let manifest = """
        {"schemaVersion":1,"githubSubmission":true,"githubStarterRepository":"cs101/lab1-starter",\
        "submissionMode":"uploadOnly","testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()

    let app: Application
    let directory: URL
    let tarballRequests = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-starter")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-starter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        let tarballRequests = tarballRequests
        let all = [Self.copy, Self.other, Self.open]
        // As GitHub does: the list carries no template, and a read by ID does.
        let listed = all.map { repository in
            var bare = repository
            bare.templateFullName = nil
            return bare
        }
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, login in
                login == "octo-student" ? GitHubInstallation(id: 5, accountID: Self.githubUserID) : nil
            },
            createInstallationToken: { _, _ in
                GitHubInstallationToken(token: "installation-token", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in listed },
            repository: { _, id in all.first { $0.id == id } },
            branches: { _, _ in ["main"] },
            commit: { _, _, _ in GitHubCommit(sha: Self.sha, message: "Finish lab 1") },
            tarball: { _, fullName, sha, _ in
                tarballRequests.withLockedValue { $0.append("\(fullName)@\(sha)") }
                return try await GitHubTarballFixture.make(files: ["main.py": "print(1)\n"], symlinks: [:])
            })
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
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

    /// An enrolled, linked student with an open, opted-in assignment.
    private func student(manifest: String = manifest) async throws -> String {
        let cookie = try await loginUser(username: "gh_starter", password: "testpassword", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_starter").first())
        try await wrEnrollUser(user, on: app)
        try await wrInsertSetup(id: "gh_starter_setup", manifest: manifest, on: app)
        try await wrInsertAssignment(testSetupID: "gh_starter_setup", title: "Lab 1", isOpen: true, on: app)
        try await APIGitHubAccountLink(
            userID: try user.requireID(), githubUserID: Self.githubUserID, githubLogin: "octo-student"
        ).save(on: app.db)
        return cookie
    }

    private func page(_ query: String, cookie: String) async throws -> String {
        let response = try await getResponse("/testsetups/gh_starter_setup/github\(query)", cookie: cookie, on: app)
        #expect(response.status == .ok)
        return response.body.string
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

    // MARK: - The live client

    /// A repository read by its ID carries the template it was made from.
    @Test func theLiveClientReadsTheTemplateARepositoryWasMadeFrom() async throws {
        try await withApp(app) { app throws in
            let github = app.useScriptedGitHub()
            let url = "GET https://api.github.com/repositories/100"
            let body = { (template: String) in
                #"{"id":100,"full_name":"octo-student/lab1","private":true,"default_branch":"main","#
                    + #""owner":{"login":"octo-student","id":9001}\#(template)}"#
            }
            github.script.withLockedValue {
                $0[url] = .json(body(#","template_repository":{"id":7,"full_name":"cs101/lab1-starter"}"#))
            }
            let client = GitHubRepoClient.live(app: app)
            #expect(try await client.repository("t", 100)?.templateFullName == "cs101/lab1-starter")
            github.script.withLockedValue { $0[url] = .json(body(#","template_repository":null"#)) }
            #expect(try await client.repository("t", 100)?.templateFullName == nil)
            github.script.withLockedValue { $0[url] = .json(body("")) }
            #expect(try await client.repository("t", 100)?.templateFullName == nil)
        }
    }

    // MARK: - The student side

    @Test func thePageLinksToTheStarter() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let body = try await page("", cookie: try await student())
            #expect(body.contains("Starter repository"))
            #expect(body.contains(#"href="https://github.com/cs101/lab1-starter""#))
            #expect(body.contains("Use this template"))
        }
    }

    @Test func withNoStarterThePageHasNoStarterSection() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let manifest = #"{"schemaVersion":1,"githubSubmission":true,"submissionMode":"uploadOnly"}"#
            let body = try await page("", cookie: try await student(manifest: manifest))
            #expect(!body.contains("Starter repository"))
            #expect(!body.contains("not made from the starter"))
        }
    }

    @Test func aCopyOfTheStarterHasNoNote() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let body = try await page("?repo=\(Self.copy.id)", cookie: try await student())
            #expect(body.contains("Submit commit 0123abc"))
            #expect(!body.contains("not made from the starter"))
        }
    }

    @Test func anotherRepositoryGetsANoteAndCanStillBeSubmitted() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let body = try await page("?repo=\(Self.other.id)", cookie: try await student())
            #expect(body.contains("This repository was not made from the starter repository."))
            #expect(body.contains("Submit commit 0123abc"))
        }
    }

    @Test func aPublicRepositoryIsRefusedOnThePage() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let body = try await page("?repo=\(Self.open.id)", cookie: try await student())
            #expect(body.contains(GitHubSubmitError.notPrivate.message))
            #expect(body.contains(#"role="alert""#))
            #expect(!body.contains("Submit commit"))
            #expect(body.contains("octo-student/public-lab1"), "the list stays, so another can be chosen")
        }
    }

    @Test func aPublicRepositoryIsRefusedAtTheSubmitBeforeAnyDownload() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let cookie = try await student()
            try await post(
                "/testsetups/gh_starter_setup/github",
                form: ["repositoryID": String(Self.open.id), "sha": Self.sha, "branch": "main"], cookie: cookie
            ) { res in
                #expect(res.headers.first(name: .location)?.hasSuffix("error=notPrivate") == true)
            }
            #expect(try await APISubmission.query(on: app.db).count() == 0)
            #expect(tarballRequests.withLockedValue { $0 }.isEmpty)
        }
    }

    // MARK: - The instructor setting

    private func instructorAssignment(
        manifest: String = #"{"schemaVersion":1}"#
    ) async throws -> (
        cookie: String, path: String, editPath: String
    ) {
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        try await wrInsertSetup(id: "gh_starter_edit", manifest: manifest, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: "gh_starter_edit", title: "Lab", isOpen: true, on: app)
        let editPath = "/instructor/\(assignment.publicID)/edit"
        return (cookie, "/instructor/\(assignment.publicID)/github-submission", editPath)
    }

    private func storedStarter() async throws -> String? {
        try await APITestSetup.find("gh_starter_edit", on: app.db)?.decodedManifest()?.githubStarterRepository
    }

    @Test func theStarterIsSavedFromAURLAsOwnerAndName() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let (cookie, path, editPath) = try await instructorAssignment()
            try await post(
                path, form: ["enabled": "on", "starterRepository": "https://github.com/cs101/lab1-starter.git"],
                cookie: cookie
            ) { res in #expect(res.status == .seeOther) }
            #expect(try await storedStarter() == "cs101/lab1-starter")
            let edit = try await getResponse(editPath, cookie: cookie, on: app)
            #expect(edit.body.string.contains(#"value="cs101/lab1-starter""#))
        }
    }

    @Test func anInvalidStarterIsRefusedAndChangesNothing() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let (cookie, path, editPath) = try await instructorAssignment()
            let form = ["enabled": "on", "starterRepository": "not a repository"]
            try await post(path, form: form, cookie: cookie) { res in
                #expect(res.headers.first(name: .location)?.hasPrefix(editPath + "?error=") == true)
            }
            let manifest = try await APITestSetup.find("gh_starter_edit", on: app.db)?.decodedManifest()
            #expect(manifest?.githubSubmission == false)
            #expect(manifest?.githubStarterRepository == nil)
        }
    }

    @Test func anEmptyStarterOrSubmissionOffClearsIt() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let (cookie, path, _) = try await instructorAssignment(
                manifest: #"{"schemaVersion":1,"githubSubmission":true,"githubStarterRepository":"cs101/lab1"}"#)
            try await post(path, form: ["enabled": "on", "starterRepository": "  "], cookie: cookie) { _ in }
            #expect(try await storedStarter() == nil)

            try await post(path, form: ["enabled": "on", "starterRepository": "cs101/lab1"], cookie: cookie) { _ in }
            #expect(try await storedStarter() == "cs101/lab1")
            try await post(path, form: ["starterRepository": "cs101/lab1"], cookie: cookie) { _ in }
            #expect(try await storedStarter() == nil, "the starter never outlives submission")
        }
    }
}
