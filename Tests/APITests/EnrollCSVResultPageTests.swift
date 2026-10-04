// Tests/APITests/EnrollCSVResultPageTests.swift
//
// The CSV enrollment result page reads only what its context encodes
// (#1973). It used to read three computed properties, which synthesized
// `Encodable` never encodes, so the rejected count, the pre-enrolled note
// and the rejected-usernames section never rendered.

import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) final class EnrollCSVResultPageTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-enroll-csv-result")
    }

    private func render(
        preEnrolledCount: Int, rejectedUsernames: [String], on app: Application
    ) async throws -> String {
        let context = EnrollCSVResultContext(
            currentUser: nil, courseCode: "CS100", courseName: "Intro", enrolledCount: 3,
            preEnrolledCount: preEnrolledCount, alreadyEnrolledCount: 1,
            rejectedUsernames: rejectedUsernames, returnURL: "/instructor")
        let view = try await app.view.render("admin-enroll-csv-result", context)
        return String(buffer: view.data)
    }

    /// The value the page shows in the Rejected row.
    private func rejectedRowValue(in html: String) throws -> String {
        let label = try #require(html.range(of: "Rejected (invalid format)</dt>"))
        let open = try #require(html.range(of: "<dd>", range: label.upperBound..<html.endIndex))
        let close = try #require(html.range(of: "</dd>", range: open.upperBound..<html.endIndex))
        return String(html[open.upperBound..<close.lowerBound])
    }

    @Test func rejectedUsernamesAndThePreEnrolledNoteRender() async throws {
        try await withApp(app) { app in
            let html = try await render(
                preEnrolledCount: 2, rejectedUsernames: ["toolong_username", "bad;name"], on: app)
            #expect(html.contains("Rejected usernames"))
            #expect(html.contains("toolong_username"))
            #expect(html.contains("joins the roster"))
            #expect(try rejectedRowValue(in: html) == "2")
        }
    }

    @Test func aCleanUploadShowsNeitherBlock() async throws {
        try await withApp(app) { app in
            let html = try await render(preEnrolledCount: 0, rejectedUsernames: [], on: app)
            #expect(!html.contains("Rejected usernames"))
            #expect(!html.contains("joins the roster"))
            #expect(try rejectedRowValue(in: html) == "0")
        }
    }
}
