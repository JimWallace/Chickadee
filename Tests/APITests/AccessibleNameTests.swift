// Tests/APITests/AccessibleNameTests.swift
//
// WCAG 2.5.3 (axe `label-content-name-mismatch`): a control's accessible name
// holds its visible text, so a voice-control user who says what they see
// reaches it. axe-core 4.14 found two controls that broke this on every page:
// the account menu button, named "Account menu" while it shows the user's
// name, and the cyclable diagnostic cards, whose `aria-label` held neither the
// window chip nor the value. These pin the fix at the markup level; the axe
// scan in the visual-regression job checks the rendered pages.

import Elementary
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct AccessibleNameTests {

    // MARK: - The account menu

    @Test func theAccountMenuIsNamedByTheVisibleNameFirst() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let html = try await getHTML("/", cookie: cookie, on: app)

            let start = try #require(html.range(of: "nav-username"), "no account menu")
            let end = try #require(html[start.upperBound...].range(of: "</button>"), "account menu not closed")
            let toggle = String(html[start.lowerBound..<end.lowerBound])

            let label = try #require(
                toggle.firstMatch(of: /aria-label="([^"]*)"/)?.output.1, "the toggle has no aria-label")
            let suffix = ", account menu"
            #expect(label.hasSuffix(suffix), "label: \(label)")
            let visibleName = label.dropLast(suffix.count)
            #expect(!visibleName.isEmpty)
            #expect(toggle.contains("<span>\(visibleName)</span>"), "the label must start with the name shown")
        }
    }

    // MARK: - The cyclable diagnostic cards

    @Test(arguments: [MetricsDiagnosticCard.Hook.admin, .instructor])
    func aMetricsCardIsNamedByItsContent(hook: MetricsDiagnosticCard.Hook) {
        let html = MetricsDiagnosticCard(hook: hook, key: "load", label: "Max Load", valueID: "v").render()
        #expect(!html.contains("aria-label"), "the content names the card, not a label")
        #expect(html.contains(#"class="diagnostic-window-chip" aria-hidden="true">24h<"#))
        #expect(html.contains(#">last 24 hours</span>"#))
        // Every window's words ride on the span, for ChickadeeSparkline.setWindow.
        #expect(html.contains(#"data-phrase-24h="last 24 hours""#))
        #expect(html.contains(#"data-phrase-7d="last 7 days""#))
        #expect(html.contains(#"data-phrase-30d="last 30 days""#))
        #expect(html.contains("Max Load"))
        #expect(html.contains("Press to change the time window."))
    }

    @Test(arguments: [("24h", "last 24 hours"), ("7d", "last 7 days"), ("30d", "last 30 days"), ("90d", "90d")])
    func aWindowChipIsSpokenInWords(chip: String, phrase: String) {
        #expect(DiagnosticWindowSpoken.phrase(for: chip) == phrase)
    }
}
