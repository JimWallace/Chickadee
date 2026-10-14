// Tests/APITests/InstructorTabbedSectionsTests.swift
//
// The instructor tabbed archetype is the tab bar, then `.page-section` blocks
// (docs/ui-design.md, Page archetypes). After the tab bar, `<main>` holds only
// sections, flash banners, the avatar sprite, scripts and styles. A titlebar or
// a table directly under the tab bar is the drift this rule stops.

import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct InstructorTabbedSectionsTests {

    /// The top-level elements after the tab bar that are not allowed there.
    static func looseContent(in main: String) -> [String] {
        let tags = RenderedMarkupRules.topLevelOpenTags(in: main)
        guard let nav = tags.firstIndex(where: { $0.hasPrefix(#"<nav class="instructor-tabs""#) }) else {
            return ["no instructor tab bar"]
        }
        return tags[(nav + 1)...].filter { tag in
            let allowed =
                tag.range(of: #"^<section class="[^"]*\bpage-section\b"#, options: .regularExpression) != nil
                || tag.range(of: #"^<div class="flash\b"#, options: .regularExpression) != nil
                || tag.hasPrefix("<script") || tag.hasPrefix("<style") || tag.hasPrefix("<svg")
            return !allowed
        }
    }

    @Test func everyInstructorTabbedPageKeepsItsContentInSections() throws {
        for fixture in ElementaryPageFixtures.all where fixture.archetype == .instructorTabbed {
            for html in fixture.renders {
                let main = try #require(RenderedMarkupRules.mainContent(of: html))
                let loose = Self.looseContent(in: main)
                #expect(loose.isEmpty, "\(fixture.typeName): \(loose)")
            }
        }
    }

    @Test func theRuleRejectsATitlebarUnderTheTabBar() {
        let tabs = InstructorTabs(active: .activity).render()
        let section = #"<section class="page-section"><h2>A</h2></section>"#
        let titlebar = #"<div class="page-titlebar"><h2>A</h2></div>"#
        #expect(Self.looseContent(in: tabs + section).isEmpty)
        #expect(Self.looseContent(in: tabs + titlebar + section) == [#"<div class="page-titlebar">"#])
        #expect(Self.looseContent(in: tabs + #"<section class="card page-section"></section>"#).isEmpty)
        #expect(Self.looseContent(in: tabs + #"<script src="/x.js"></script>"#).isEmpty)
        // An icon inside a section must not hide loose content after it.
        let icon = ##"<section class="page-section"><svg class="icon"><use href="#i-x"></use></svg></section>"##
        #expect(Self.looseContent(in: tabs + icon + titlebar) == [#"<div class="page-titlebar">"#])
    }
}
