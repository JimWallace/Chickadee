// Tests/APITests/Pages/RowMenuTests.swift

import Elementary
import Foundation
import Testing

@testable import APIServer

/// `RowMenu` is the one place that writes the trailing ⋯ menu's shell. These
/// tests pin the shell that `app.js` and `docs/ui-design.md` rely on.
@Suite struct RowMenuTests {

    private let html = RowMenu(for: "CS135") {
        a(.class("row-menu-item"), .href("/x"), .role("menuitem")) { "Open" }
    }.render()

    @Test func theSummaryNamesTheRow() {
        #expect(html.contains(#"aria-label="More actions for CS135""#))
        #expect(html.contains(#"title="More actions""#))
    }

    @Test func theShellIsADisclosureWithAMenuPanel() {
        #expect(html.hasPrefix(#"<details class="ext-details row-menu"><summary"#))
        #expect(html.contains(#"<div class="popover-panel row-menu-panel" role="menu">"#))
        #expect(html.hasSuffix("</div></details>"))
    }

    @Test func theItemsSitInsideThePanel() throws {
        let panel = try #require(html.range(of: #"role="menu">"#))
        let item = try #require(html.range(of: #"<a class="row-menu-item""#))
        #expect(item.lowerBound >= panel.upperBound)
    }

    /// A quote in the subject cannot end the attribute.
    @Test func aQuoteInTheSubjectIsEscaped() {
        let escaped = RowMenu(for: #"a "b" & c"#) { "" }.render()
        #expect(escaped.contains(#"aria-label="More actions for a &quot;b&quot; &amp; c""#))
    }
}
