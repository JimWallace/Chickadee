// Tests/APITests/NewTabLinkTests.swift
//
// The link that opens in a new tab: the target, the external icon, the words
// for a screen reader, and the attributes a caller adds.

import Elementary
import Testing

@testable import APIServer

@Suite struct NewTabLinkTests {

    @Test func aLinkOpensANewTabAndSaysSo() {
        let html = NewTabLink(href: "https://example.test/help", text: "Help ").render()
        #expect(html.contains(#"href="https://example.test/help""#))
        #expect(html.contains(#"target="_blank""#))
        #expect(html.contains(#"rel="noopener noreferrer""#))
        #expect(html.contains("#i-external"))
        #expect(html.contains("(opens in a new tab)"))
        #expect(html.contains("Help "))
    }

    @Test func theCallersAttributesGoOnTheAnchor() {
        let html = NewTabLink(
            href: "/x", text: "Help", attributes: [.class("row-menu-item"), .role("menuitem")]
        ).render()
        #expect(html.hasPrefix("<a "))
        #expect(html.contains(#"class="row-menu-item""#))
        #expect(html.contains(#"role="menuitem""#))
    }
}
