// Tests/APITests/RowMenuMarkupTests.swift
//
// The row menu (the trailing ⋯) and the shared list-filter threshold.
//
// A menu with nothing in it is a control that opens onto a blank panel, so the
// rule is structural: every `.row-menu` popup in a template carries at least
// one `.row-menu-item`, and its summary names the row it acts on. Leaf decides
// at render time whether a conditional item appears, so a template that can
// render an empty panel guards the whole menu with the same condition.

import Foundation
import Testing

@testable import APIServer

@Suite struct RowMenuMarkupTests {

    private struct Menu {
        let file: String
        let block: String
    }

    /// The text of every `<details class="… row-menu …">` element, open tag to
    /// closing tag. Row menus never nest, so the first `</details>` closes it.
    private static func menuBlocks(in html: String) -> [String] {
        var blocks: [String] = []
        for tag in LeafMarkupScanner.openTags("details", in: html)
        where LeafMarkupScanner.tagCarriesClass("row-menu", in: tag.text) {
            let rest = html[tag.index...]
            guard let close = rest.range(of: "</details>") else { continue }
            blocks.append(String(rest[..<close.upperBound]))
        }
        return blocks
    }

    private static func menus() throws -> [Menu] {
        var found: [Menu] = []
        for file in try LeafMarkupScanner.templateNames() {
            let html = try LeafMarkupScanner.markup(of: file)
            found += menuBlocks(in: html).map { Menu(file: file, block: $0) }
        }
        return found
    }

    @Test func aMenuWithoutItemsIsDetected() {
        let empty = #"<details class="ext-details row-menu"><summary></summary><div></div></details>"#
        let full =
            #"<details class="ext-details row-menu"><summary></summary><button class="row-menu-item"></button></details>"#
        #expect(Self.menuBlocks(in: empty).count == 1)
        #expect(!Self.menuBlocks(in: empty)[0].contains("row-menu-item"))
        #expect(Self.menuBlocks(in: full)[0].contains("row-menu-item"))
    }

    @Test func noRowMenuIsEmpty() throws {
        for menu in try Self.menus() {
            #expect(
                menu.block.contains("row-menu-item"),
                "\(menu.file): a row menu with no items — hide the whole menu when it has nothing to offer")
        }
    }

    @Test func everyRowMenuSummaryNamesItsRow() throws {
        for menu in try Self.menus() {
            #expect(
                menu.block.contains("aria-label=\"More actions for"),
                "\(menu.file): the ⋯ summary must say which row it belongs to")
        }
    }
}

@Suite struct ListFilterPolicyTests {
    @Test func filterAppearsAtTheThreshold() {
        #expect(ListFilterPolicy.minimumRows == 8)
        #expect(!ListFilterPolicy.showsFilter(rowCount: 7))
        #expect(ListFilterPolicy.showsFilter(rowCount: 8))
    }

    @Test func dashboardGroupsShareTheSameThreshold() {
        #expect(IndexDisplayGroup.filterThreshold == ListFilterPolicy.minimumRows)
    }
}
