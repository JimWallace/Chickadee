// Tests/APITests/Courses/CourseBundleExportTempPathTests.swift
//
// A course export writes its temp zip to a unique path (#2767). Before the
// fix the path was `<tmp>/chickadee-bundle-<code>-<date>.zip`, so a file
// already at that path (a second same-day export of the same course) was
// appended to, and the first stream's cleanup could delete it.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .requiresZipTools, .timeLimit(.minutes(2)))
final class CourseBundleExportTempPathTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtemp")
    }

    @Test func exportLeavesAFileAtTheDownloadNamePathAlone() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cbtemp", on: app)
            let code = "TMP\(UUID().uuidString.prefix(8))"
            let course = APICourse(code: code, name: "Temp Path Course")
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString

            let downloadName = "chickadee-bundle-\(code)-\(iso8601String(Date()).prefix(10)).zip"
            let sharedPath = FileManager.default.temporaryDirectory
                .appendingPathComponent(downloadName).path
            let sentinel = Data("another export in flight".utf8)
            try sentinel.write(to: URL(fileURLWithPath: sharedPath))
            defer { try? FileManager.default.removeItem(atPath: sharedPath) }

            try await app.asyncTest(
                .GET, "/admin/courses/\(id)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let disposition = res.headers.first(name: .contentDisposition) ?? ""
                    #expect(disposition.contains(downloadName), "download name changed: \(disposition)")
                }
            )

            let after = try Data(contentsOf: URL(fileURLWithPath: sharedPath))
            #expect(after == sentinel)
        }
    }
}
