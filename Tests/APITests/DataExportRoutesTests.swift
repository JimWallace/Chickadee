// Tests/APITests/DataExportRoutesTests.swift
//
// Integration tests for the personal-data export (#557):
//   POST /account/export           — request, async generation, rate limit
//   GET  /account/export/status    — poll JSON
//   GET  /account/export/download  — owner-scoped zip download
//
// Key behaviours under test:
//   - Requesting an export generates a downloadable zip containing the
//     README manifest, profile, enrollments, submission metadata, the
//     uploaded submission file, and tier-filtered results
//   - Secret-tier outcomes are NOT itemized in the exported results
//   - One export per day per user (second request is rejected)
//   - The export contains only the requesting user's data
//   - Request + download are audit-logged
//   - Unauthenticated access redirects to /login

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) final class DataExportRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dexp")
    }

    // MARK: - Helpers

    private struct ExportTimeout: Error {}

    /// Polls the user's export row until generation reaches a terminal
    /// state (the POST handler runs it in a background task).
    private func waitForTerminalExport(
        userID: UUID, timeoutSeconds: Double = 30
    ) async throws -> APIDataExport {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let row = try await APIDataExport.query(on: app.db)
                .filter(\.$userID == userID)
                .first(),
                row.statusValue != .pending
            {
                return row
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ExportTimeout()
    }

    private func requestExport(cookie: String) async throws -> String? {
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, "/account/export",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    /// Downloads the caller's export and extracts it into a temp dir the
    /// caller is responsible for deleting.
    private func downloadAndExtract(cookie: String) async throws -> URL {
        var body = Data()
        try await app.asyncTest(
            .GET, "/account/export/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/zip")
                let disposition = res.headers.first(name: .contentDisposition) ?? ""
                #expect(disposition.contains("attachment"))
                #expect(disposition.contains("chickadee-data-export-"))
                body = Data(res.body.readableBytesView)
            })
        #expect(!body.isEmpty)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dexp-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let zipURL = scratch.appendingPathComponent("export.zip")
        try body.write(to: zipURL)
        let contents = scratch.appendingPathComponent("contents")
        try await extractZipArchive(zipPath: zipURL.path, into: contents)
        return scratch
    }

    private func auditCount(action: AuditAction, actorUserID: UUID) async throws -> Int {
        try await APIAuditLogEntry.query(on: app.db)
            .filter(\.$action == action.rawValue)
            .filter(\.$actorUserID == actorUserID)
            .count()
    }

    // MARK: - Unauthenticated access

    @Test func requestExport_unauthenticated_redirectsToLogin() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(.POST, "/account/export") { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }
            try await app.asyncTest(.GET, "/account/export/download") { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }
        }
    }

    // MARK: - Happy path

    @Test func requestExport_generatesDownloadableZip() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let studentID = try student.requireID()
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "setup_001", on: app)
            try await wrInsertAssignment(
                testSetupID: "setup_001", title: "Warmup Lab", isOpen: true, on: app)
            let submission = try await wrInsertSubmission(
                id: "sub_export_1", testSetupID: "setup_001", userID: studentID,
                filename: "warmup.py", on: app)
            let sourceCode = "print('export me')\n"
            try Data(sourceCode.utf8).write(to: URL(fileURLWithPath: submission.zipPath))
            try await wrInsertResult(
                submissionID: "sub_export_1",
                outcomes: [
                    wrMakeOutcome(name: "test_alpha", tier: .pub, status: .pass),
                    wrMakeOutcome(name: "test_hidden_secret", tier: .secret, status: .fail),
                ],
                on: app)

            let location = try await requestExport(cookie: cookie)
            #expect(location == "/account?exportNotice=started")

            let row = try await waitForTerminalExport(userID: studentID)
            #expect(row.statusValue == .complete, "failure: \(row.failureReason ?? "nil")")
            let zipPath = try #require(row.zipPath)
            #expect(FileManager.default.fileExists(atPath: zipPath))
            #expect((row.fileSizeBytes ?? 0) > 0)
            #expect(row.completedAt != nil)
            #expect(try await auditCount(action: .userDataExportRequested, actorUserID: studentID) == 1)

            let scratch = try await downloadAndExtract(cookie: cookie)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let contents = scratch.appendingPathComponent("contents")

            let readme = try String(
                contentsOf: contents.appendingPathComponent("README.md"), encoding: .utf8)
            #expect(readme.contains("Chickadee data export"))
            #expect(readme.contains("student1"))

            let profile = try String(
                contentsOf: contents.appendingPathComponent("profile.json"), encoding: .utf8)
            #expect(profile.contains("\"username\" : \"student1\""))
            #expect(!profile.contains("passwordHash"))

            let enrollments = try String(
                contentsOf: contents.appendingPathComponent("enrollments.json"), encoding: .utf8)
            #expect(enrollments.contains("CS101"))

            let submissionsIndex = try String(
                contentsOf: contents.appendingPathComponent("submissions.json"), encoding: .utf8)
            #expect(submissionsIndex.contains("sub_export_1"))
            #expect(submissionsIndex.contains("Warmup Lab"))
            #expect(submissionsIndex.contains("warmup.py"))

            let copiedFile = contents.appendingPathComponent(
                "submissions/sub_export_1/sub_export_1.py")
            #expect(try String(contentsOf: copiedFile, encoding: .utf8) == sourceCode)

            // Results are tier-filtered like the results API: the public
            // outcome is itemized, the secret one is not (aggregate counts
            // still reflect the full run).
            let results = try String(
                contentsOf: contents.appendingPathComponent(
                    "submissions/sub_export_1/results.json"),
                encoding: .utf8)
            #expect(results.contains("test_alpha"))
            #expect(!results.contains("test_hidden_secret"))
            #expect(results.contains("\"totalTests\" : 2"))

            #expect(
                FileManager.default.fileExists(
                    atPath: contents.appendingPathComponent("audit-log.json").path))
            #expect(
                FileManager.default.fileExists(
                    atPath: contents.appendingPathComponent("grading-adjustments.json").path))

            #expect(
                try await auditCount(action: .userDataExportDownloaded, actorUserID: studentID)
                    == 1)
        }
    }

    // MARK: - Rate limiting

    @Test func requestExport_secondRequestSameDay_isRateLimited() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let studentID = try student.requireID()

            let first = try await requestExport(cookie: cookie)
            #expect(first == "/account?exportNotice=started")
            let row = try await waitForTerminalExport(userID: studentID)
            #expect(row.statusValue == .complete)
            let firstRequestedAt = row.requestedAt

            let second = try await requestExport(cookie: cookie)
            #expect(second == "/account?exportError=rate_limited")

            // Still exactly one row, untouched by the rejected request.
            let rows = try await APIDataExport.query(on: app.db)
                .filter(\.$userID == studentID)
                .all()
            #expect(rows.count == 1)
            #expect(rows.first?.statusValue == .complete)
            #expect(rows.first?.requestedAt == firstRequestedAt)
            #expect(try await auditCount(action: .userDataExportRequested, actorUserID: studentID) == 1)
        }
    }

    // MARK: - Download gating

    @Test func download_withNoExport_redirectsNotReady() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, "/account/export/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location) == "/account?exportError=not_ready")
                })
        }
    }

    // MARK: - Scoping

    @Test func export_containsOnlyRequestingUsersData() async throws {
        try await withApp(app) { _ in
            // student1 owns a submission; the export is requested by someone else.
            _ = try await wrLoginAsStudent(on: app)
            let student1 = try await wrStudentUser(on: app)
            try await wrEnrollUser(student1, on: app)
            try await wrInsertSetup(id: "setup_001", on: app)
            try await wrInsertSubmission(
                id: "sub_other_user", testSetupID: "setup_001",
                userID: try student1.requireID(), on: app)

            let otherCookie = try await loginUser(
                username: "exporter2", password: "pass", role: "student", on: app)
            let other = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "exporter2").first())
            let otherID = try other.requireID()

            _ = try await requestExport(cookie: otherCookie)
            let row = try await waitForTerminalExport(userID: otherID)
            #expect(row.statusValue == .complete)

            let scratch = try await downloadAndExtract(cookie: otherCookie)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let contents = scratch.appendingPathComponent("contents")

            let profile = try String(
                contentsOf: contents.appendingPathComponent("profile.json"), encoding: .utf8)
            #expect(profile.contains("exporter2"))
            #expect(!profile.contains("student1"))

            let submissionsIndex = try String(
                contentsOf: contents.appendingPathComponent("submissions.json"), encoding: .utf8)
            #expect(!submissionsIndex.contains("sub_other_user"))
            #expect(
                !FileManager.default.fileExists(
                    atPath: contents.appendingPathComponent("submissions").path))
        }
    }

    // MARK: - Status endpoint + account page

    @Test func exportStatus_reflectsRowState() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let studentID = try student.requireID()

            try await app.asyncTest(
                .GET, "/account/export/status",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("\"status\":\"none\""))
                })

            _ = try await requestExport(cookie: cookie)
            _ = try await waitForTerminalExport(userID: studentID)

            try await app.asyncTest(
                .GET, "/account/export/status",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("\"status\":\"complete\""))
                })
        }
    }

    @Test func accountPage_rendersExportSection() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let page = res.body.string
                    #expect(page.contains("Your data"))
                    #expect(page.contains("Request data export"))
                    #expect(page.contains("/account/export"))
                })
        }
    }

    // MARK: - Retention reaper

    @Test func reaper_removesExpiredExportAndZip() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let studentID = try student.requireID()

            _ = try await requestExport(cookie: cookie)
            let row = try await waitForTerminalExport(userID: studentID)
            let zipPath = try #require(row.zipPath)
            #expect(FileManager.default.fileExists(atPath: zipPath))

            // Not yet expired: sweep with "now" inside the retention window.
            try await reapExpiredDataExports(on: app.db, logger: app.logger, now: Date())
            #expect(
                try await APIDataExport.query(on: app.db).filter(\.$userID == studentID).count()
                    == 1)

            // Expired: sweep as if the retention window has passed.
            let later = Date().addingTimeInterval(dataExportRetentionMaxAge + 60)
            try await reapExpiredDataExports(on: app.db, logger: app.logger, now: later)
            #expect(
                try await APIDataExport.query(on: app.db).filter(\.$userID == studentID).count()
                    == 0)
            #expect(!FileManager.default.fileExists(atPath: zipPath))
        }
    }
}

/// Pure policy tests for the request gate — no app fixture needed.
@Suite struct DataExportPolicyTests {

    @Test func canBeRequested_stateMachine() {
        let now = Date()
        #expect(dataExportCanBeRequested(nil, now: now))

        let userID = UUID()
        let fresh = APIDataExport(userID: userID, requestedAt: now.addingTimeInterval(-60))
        #expect(!dataExportCanBeRequested(fresh, now: now))

        let stalePending = APIDataExport(
            userID: userID, requestedAt: now.addingTimeInterval(-dataExportStalePendingAge - 1))
        #expect(dataExportCanBeRequested(stalePending, now: now))

        let completeToday = APIDataExport(
            userID: userID, requestedAt: now.addingTimeInterval(-3600))
        completeToday.setStatus(.complete)
        #expect(!dataExportCanBeRequested(completeToday, now: now))

        let completeYesterday = APIDataExport(
            userID: userID,
            requestedAt: now.addingTimeInterval(-dataExportMinRequestInterval - 1))
        completeYesterday.setStatus(.complete)
        #expect(dataExportCanBeRequested(completeYesterday, now: now))

        let failed = APIDataExport(userID: userID, requestedAt: now.addingTimeInterval(-60))
        failed.setStatus(.failed)
        #expect(dataExportCanBeRequested(failed, now: now))
    }
}
