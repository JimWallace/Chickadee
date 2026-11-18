// Tests/APITests/Admin/AdminDeploymentModeMarkupTests.swift
//
// The Deployment page's Mode section is one choice of three, so it is a
// radio group with one Save button that asks first, not a row of "Switch"
// buttons (docs/ui-design.md, `.fieldset-plain`). Where no request can be
// sent, the same radios show, disabled. Rendered from the page fixtures:
// a held minor in gated-minors, an approved release in manual, and a host
// with no deploy daemon.

import Foundation
import Testing

@testable import APIServer

@Suite struct AdminDeploymentModeMarkupTests {

    private static var renders: [String] { ElementaryPageFixtures.adminDeploymentPage.renders }

    private static func radios(in html: String) -> [String] {
        html.matches(of: /<input type="radio" name="mode"[^>]*>/).map { String($0.output) }
    }

    @Test func theCurrentModeIsTheCheckedRadio() throws {
        let gated = try #require(Self.renders.first)
        #expect(Self.radios(in: gated).count == DeployMode.allCases.count)
        #expect(gated.contains(#"value="gated-minors" checked"#))
        #expect(!gated.contains(#"value="autonomous" checked"#))
        let manual = try #require(Self.renders.dropFirst().first)
        #expect(manual.contains(#"value="manual" checked"#))
    }

    @Test func oneSaveButtonAsksBeforeItSends() throws {
        let html = try #require(Self.renders.first)
        #expect(html.contains("Save mode"))
        #expect(!html.contains(">Switch<"))
        let form = try #require(html.firstMatch(of: /<form[^>]*action="\/admin\/deployment\/mode"[^>]*>/))
        #expect(form.output.contains("data-confirm="))
    }

    @Test func theDefaultModeSaysSoInItsName() throws {
        let html = try #require(Self.renders.first)
        #expect(html.contains("Gated minors (default)"))
        #expect(!html.contains("Autonomous (default)"))
    }

    @Test func withoutTheDaemonTheModesShowDisabledWithNoForm() throws {
        let html = try #require(Self.renders.last)
        #expect(!html.contains(#"action="/admin/deployment/mode""#))
        #expect(Self.radios(in: html).count == DeployMode.allCases.count)
        #expect(html.contains("<fieldset class=\"fieldset-plain\" disabled>"))
    }

    @Test func theApproveButtonNamesTheVersion() throws {
        let html = try #require(Self.renders.first)
        #expect(html.contains("Approve v0.6.0"))
    }
}
