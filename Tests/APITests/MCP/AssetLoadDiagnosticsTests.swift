// Tests/APITests/MCP/AssetLoadDiagnosticsTests.swift
//
// The cold-load breadcrumbs end to end: POST /api/v1/client-diagnostics
// accepts an `asset_load`, and `get_browser_diagnostics` folds such rows into
// `assetLoads` (per source) and `assetLoadsByDay`. The parsing and the
// arithmetic themselves are pinned in AssetLoadStatsTests.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssetLoadDiagnosticsTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "asset-load-diag")
    }

    private func context(subject: String) -> AdminToolContext {
        AdminToolContext(request: makeTestRequest(on: app), subject: subject, grantedScopes: [.read])
    }

    @Test func theEndpointAcceptsAnAssetLoadBreadcrumb() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(username: "al_student", password: "pass", role: "student", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let res = try await app.asyncSendRequest(.POST, "/api/v1/client-diagnostics") { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(
                    string: #"{"kind":"asset_load","source":"editor","message":"cold=1;net_bytes=900;cache_bytes=100"}"#
                )
            }
            #expect(res.status == .accepted)
            let rows = try await APIClientDiagnostic.query(on: app.db).filter(\.$kind == "asset_load").all()
            #expect(rows.count == 1)
            #expect(rows.first?.source == "editor")
            #expect(rows.first?.message == "cold=1;net_bytes=900;cache_bytes=100")
        }
    }

    @Test func browserDiagnosticsReportsColdLoadsPerSourceAndDay() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "al-admin", role: "admin")
            let student = try await makeTestUser(on: app, username: "al-student2", role: "student")
            let studentID = try student.requireID()
            let seeds: [(source: String, message: String)] = [
                ("editor", "cold=1;net_bytes=40000000;cache_bytes=0;boot_ms=30000"),
                ("editor", "cold=0;net_bytes=0;cache_bytes=48000000;boot_ms=9000"),
                ("editor", "probe=unsupported;boot_ms=12000"),
                ("prewarm", "cold=1;net_bytes=48000000;cache_bytes=0;warm_ms=60000"),
            ]
            for seed in seeds {
                try await APIClientDiagnostic(
                    userID: studentID, testSetupID: nil, kind: "asset_load",
                    failedChecks: nil, userAgent: "UA", message: seed.message,
                    stack: nil, source: seed.source
                ).save(on: app.db)
            }
            // Another kind with the same source must not count.
            try await APIClientDiagnostic(
                userID: studentID, testSetupID: nil, kind: "kernel_phase",
                failedChecks: nil, userAgent: "UA", message: "cold=1",
                stack: nil, source: "editor"
            ).save(on: app.db)

            let output = try await GetBrowserDiagnosticsTool().execute(.init(), context(subject: "al-admin"))

            #expect(output.assetLoads.map(\.key) == ["editor", "prewarm"])
            let editor = try #require(output.assetLoads.first)
            #expect(editor.loads == 3)
            #expect(editor.coldLoads == 1)
            #expect(editor.unknownLoads == 1)
            #expect(editor.coldShare == 0.5)
            #expect(editor.networkBytes == 40_000_000)
            #expect(editor.cachedBytes == 48_000_000)
            #expect(editor.bootMsMedian == 12000)
            // Every row is from today, so one day key per source.
            #expect(output.assetLoadsByDay.count == 2)
            #expect(output.assetLoadsByDay.allSatisfy { $0.key.hasSuffix("/editor") || $0.key.hasSuffix("/prewarm") })
        }
    }
}
