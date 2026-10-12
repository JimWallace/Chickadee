// Tests/APITests/ElementaryPageGuardTests.swift
//
// The UI guards for Elementary views, on rendered markup. The shell guards
// read the view sources; this suite renders every page in
// ElementaryPageFixtures and holds the HTML to the rules that need the
// rendered page (docs/elementary-spike.md, "Guards").

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct ElementaryPageGuardTests {

    private static let fixtures = ElementaryPageFixtures.all

    private static var renders: [(page: String, html: String)] {
        fixtures.flatMap { fixture in fixture.renders.map { (fixture.typeName, $0) } }
    }

    // MARK: - Completeness

    /// A page type without a fixture is a page no rule below ever sees.
    ///
    /// Every file under `Views/Pages/` (at any depth) holds one page, named
    /// after the file, as CLAUDE.md requires of every file. The type named by
    /// the file must be declared there as a markup type, and must have a
    /// fixture.
    @Test func everyPageTypeHasAFixture() throws {
        let pagesDirectory = repositoryRoot.appendingPathComponent("Sources/APIServer/Views/Pages")
        let enumerator = try #require(FileManager.default.enumerator(atPath: pagesDirectory.path))
        var pageTypes: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            let typeName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let source = try String(contentsOf: pagesDirectory.appendingPathComponent(path), encoding: .utf8)
            let declaration = try Regex(#"(struct|class|enum)\s+"# + typeName + #"\b[^{]*:\s*[^{]*\bHTML(Document)?\b"#)
            #expect(source.contains(declaration), "\(path) does not declare a markup type named \(typeName)")
            pageTypes.append(typeName)
        }
        #expect(!pageTypes.isEmpty, "the scan found no page files, so it is broken, not clean")
        #expect(Set(pageTypes) == Set(Self.fixtures.map(\.typeName)))
    }

    /// The rules below read attribute values and `<style>` blocks. Renders
    /// that hold neither would pass every rule without being checked.
    @Test func everyFixtureGivesTheRulesSomethingToRead() {
        for fixture in Self.fixtures {
            #expect(!fixture.renders.isEmpty, "\(fixture.typeName) has no renders")
            for html in fixture.renders {
                #expect(RenderedMarkupRules.mainContent(of: html) != nil, "\(fixture.typeName) renders no <main>")
                #expect(
                    !RenderedMarkupRules.attributeValues(named: "class", in: html).isEmpty,
                    "\(fixture.typeName) renders no class attribute, so the class rule reads nothing")
            }
        }
        #expect(
            Self.renders.contains { !RenderedMarkupRules.styleBlocks(in: $0.html).isEmpty },
            "no fixture renders a page <style> block, so the CSS variable rule reads nothing")
    }

    // MARK: - The rules

    @Test func inlineStylesAreOnlyDisplayNoneOrCustomProperties() {
        for (page, html) in Self.renders {
            #expect(RenderedMarkupRules.inlineStyleViolations(in: html).isEmpty, "\(page)")
        }
    }

    /// An inline custom property carries a per-datum value only. The list is
    /// check-styles.sh's, and it must name every per-student avatar property.
    @Test func inlineCustomPropertiesArePerDatum() throws {
        let allowed = try RenderedMarkupRules.perDatumInlineProperties()
        #expect(allowed.contains("--bar-h"), "the list was not read from scripts/check-styles.sh")
        let avatar = AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: 1), size: .standard, accessibility: .decorative, isStaff: false)
        for property in avatar.inlineProperties {
            #expect(allowed.contains(property.name), "\(property.name) is missing from PER_DATUM_INLINE_PROPS")
        }
        #expect(
            Self.renders.contains { $0.html.contains(" style=\"--") },
            "no fixture renders an inline custom property, so this rule reads nothing")
        for (page, html) in Self.renders {
            let broken = RenderedMarkupRules.perPageInlinePropertyViolations(in: html, allowed: allowed)
            #expect(broken.isEmpty, "\(page): \(broken)")
        }
    }

    @Test func everySortableHeaderCarriesTheSharedButton() {
        #expect(
            Self.renders.contains { $0.html.contains(" data-sort-type=\"") },
            "no fixture renders a sortable header, so this rule reads nothing")
        for (page, html) in Self.renders {
            let broken = RenderedMarkupRules.orphanSortHeaderViolations(in: html)
            #expect(broken.isEmpty, "\(page): \(broken)")
        }
    }

    @Test func scriptsCarryNoInlineCodeAndNoHandlers() {
        for (page, html) in Self.renders {
            let broken = RenderedMarkupRules.scriptViolations(in: html)
            #expect(broken.isEmpty, "\(page): \(broken)")
        }
    }

    @Test func everyAssignedClassResolves() throws {
        let defined = try RenderedMarkupRules.resolvableClasses()
        #expect(defined.count > 100, "the stylesheet parse found too few classes, so it is broken")
        for (page, html) in Self.renders {
            let unresolved = RenderedMarkupRules.unresolvedClasses(in: html, defined: defined)
            #expect(unresolved.isEmpty, "\(page): \(unresolved)")
        }
    }

    @Test func everyCSSVariableInAPageBlockResolves() throws {
        let declared = try RenderedMarkupRules.declaredCustomProperties()
        #expect(declared.count > 20, "the stylesheet parse found too few custom properties, so it is broken")
        for (page, html) in Self.renders {
            let broken = RenderedMarkupRules.cssVariableViolations(in: html, declared: declared)
            #expect(broken.isEmpty, "\(page): \(broken)")
        }
    }

    @Test func hoverTextStaysShort() {
        for (page, html) in Self.renders {
            let long = RenderedMarkupRules.longTitles(in: html)
            #expect(long.isEmpty, "\(page): \(long)")
        }
    }

    @Test func headingLevelsFormASpine() throws {
        for (page, html) in Self.renders {
            let main = try #require(RenderedMarkupRules.mainContent(of: html))
            let levels = LeafMarkupScanner.headingLevels(in: main)
            if let first = levels.first {
                #expect(first <= 2, "\(page) starts at h\(first)")
            }
            for (previous, next) in zip(levels, levels.dropFirst()) {
                #expect(next <= previous + 1, "\(page) skips from h\(previous) to h\(next)")
            }
        }
    }

    /// The per-archetype rules from `PageArchetypeTests`, applied to `<main>`.
    /// Its universal rules are not applied: they read the Leaf source (the
    /// base extend, the export slots, the flash partial). The heading spine is
    /// checked above; the flash rule is still open (docs/elementary-spike.md).
    /// The tabbed and shim archetypes read Leaf partials too, and need their
    /// rules adapted before a page of that shape moves to Swift.
    ///
    /// Only exemplars are checked, as `PageArchetypeTests` checks only the
    /// exemplar templates: a page that predates the rulebook may fit no
    /// archetype exactly, and the port keeps its markup unchanged.
    @Test func everyExemplarMatchesItsArchetype() throws {
        let exemplars = Self.fixtures.filter(\.isExemplar)
        #expect(!exemplars.isEmpty, "no fixture is marked as an exemplar, so this test checks nothing")
        for fixture in exemplars {
            for html in fixture.renders {
                let main = try #require(RenderedMarkupRules.mainContent(of: html))
                let page = PageArchetypeTests.Page(file: fixture.typeName, markup: main, source: "")
                let broken = PageArchetypeTests.violations(of: fixture.archetype, in: page)
                #expect(broken.isEmpty, "\(fixture.typeName): \(broken)")
            }
        }
    }

    /// Every admin tabbed page, exemplar or not, opens with `AdminTabs`. This
    /// is the Swift half of "tab bars only through their component"; SwiftLint
    /// `elementary_tabs_only_in_component` keeps the classes out of other views.
    @Test func everyAdminTabbedPageOpensWithAdminTabs() throws {
        for fixture in Self.fixtures where fixture.archetype == .adminTabbed {
            for html in fixture.renders {
                let main = try #require(RenderedMarkupRules.mainContent(of: html))
                let broken = RenderedMarkupRules.adminTabbedViolations(in: main)
                #expect(broken.isEmpty, "\(fixture.typeName): \(broken)")
            }
        }
    }

    /// The admin tabbed rule holds for the component and fails when the page
    /// drops it, adds a second h1, or puts a section above the tab bar.
    @Test func theAdminTabbedRuleRejectsAPageThatBreaksIt() {
        let tabs = AdminTabs(active: .alerts, page: ElementaryPageFixtures.page()).render()
        let section = #"<section class="page-section"><h2>A</h2></section>"#
        #expect(RenderedMarkupRules.adminTabbedViolations(in: tabs + section).isEmpty)
        #expect(RenderedMarkupRules.adminTabbedViolations(in: section).count == 3)
        #expect(RenderedMarkupRules.adminTabbedViolations(in: tabs + "<h1>Alerts</h1>" + section).count == 1)
        #expect(RenderedMarkupRules.adminTabbedViolations(in: section + tabs).count == 1)
    }

    /// Every instructor tabbed page, exemplar or not, opens with
    /// `InstructorTabs`: the instructor half of "tab bars only through their
    /// component".
    @Test func everyInstructorTabbedPageOpensWithInstructorTabs() throws {
        for fixture in Self.fixtures where fixture.archetype == .instructorTabbed {
            for html in fixture.renders {
                let main = try #require(RenderedMarkupRules.mainContent(of: html))
                let broken = RenderedMarkupRules.instructorTabbedViolations(in: main)
                #expect(broken.isEmpty, "\(fixture.typeName): \(broken)")
            }
        }
    }

    /// The instructor tabbed rule holds for the component and fails when the
    /// page drops it, adds a second h1, or puts a section above the tab bar.
    @Test func theInstructorTabbedRuleRejectsAPageThatBreaksIt() {
        let tabs = InstructorTabs(active: .students).render()
        let section = #"<section class="page-section"><h2>A</h2></section>"#
        #expect(RenderedMarkupRules.instructorTabbedViolations(in: tabs + section).isEmpty)
        #expect(RenderedMarkupRules.instructorTabbedViolations(in: section).count == 2)
        #expect(RenderedMarkupRules.instructorTabbedViolations(in: tabs + "<h1>Students</h1>" + section).count == 1)
        #expect(RenderedMarkupRules.instructorTabbedViolations(in: section + tabs).count == 1)
    }

    // MARK: - The rules fire

    /// A guard that never fires is indistinguishable from a page that holds.
    @Test func eachRuleRejectsAPageThatBreaksIt() throws {
        #expect(RenderedMarkupRules.inlineStyleViolations(in: #"<p style="margin: 0">x</p>"#).count == 1)
        #expect(RenderedMarkupRules.inlineStyleViolations(in: #"<p style="display:none; --w: 4px">x</p>"#).isEmpty)

        #expect(RenderedMarkupRules.scriptViolations(in: "<script>alert(1)</script>").count == 1)
        #expect(RenderedMarkupRules.scriptViolations(in: #"<button onclick="go()">x</button>"#).count == 1)
        #expect(RenderedMarkupRules.scriptViolations(in: #"<button class="b" onchange ="go()">x</button>"#).count == 1)
        #expect(RenderedMarkupRules.scriptViolations(in: #"<script src="/app.js"></script>"#).isEmpty)
        #expect(
            RenderedMarkupRules.scriptViolations(in: #"<script type="application/json" id="d">{}</script>"#).isEmpty)

        let defined = try RenderedMarkupRules.resolvableClasses()
        #expect(
            RenderedMarkupRules.unresolvedClasses(in: #"<p class="no-such-class-anywhere">x</p>"#, defined: defined)
                == ["no-such-class-anywhere"])
        #expect(RenderedMarkupRules.unresolvedClasses(in: #"<p class="js-hook">x</p>"#, defined: defined).isEmpty)
        #expect(
            RenderedMarkupRules.unresolvedClasses(
                in: #"<style>.only-here { color: red; }</style><p class="only-here">x</p>"#, defined: defined
            ).isEmpty)

        let declared = try RenderedMarkupRules.declaredCustomProperties()
        #expect(
            RenderedMarkupRules.cssVariableViolations(
                in: "<style>.a { color: var(--no-such-token); }</style>", declared: declared
            ).count == 1)
        #expect(
            RenderedMarkupRules.cssVariableViolations(
                in: "<style>.a { color: var(--no-such-token, red); }</style>", declared: declared
            ).count == 1)
        #expect(
            RenderedMarkupRules.cssVariableViolations(
                in: #"<p style="--w: var(--no_such-token)">x</p>"#, declared: declared
            ) == ["var(--no_such-token) is not declared"])
        let someToken = try #require(declared.min())
        #expect(
            RenderedMarkupRules.cssVariableViolations(
                in: "<style>.a { color: var(\(someToken), var(\(someToken))); }</style>", declared: declared
            ).isEmpty)

        let longTitle = Array(repeating: "word", count: RenderedMarkupRules.titleWordCap + 1).joined(separator: " ")
        #expect(RenderedMarkupRules.longTitles(in: "<b title=\"\(longTitle)\">x</b>").count == 1)
    }

    /// The per-datum and sortable-header rules, which moved here from
    /// check-styles.sh when the Leaf templates went, each fire on their defect.
    @Test func theRulesMovedFromCheckStylesRejectAPageThatBreaksThem() throws {
        let allowed = try RenderedMarkupRules.perDatumInlineProperties()
        let perPage = RenderedMarkupRules.perPageInlinePropertyViolations
        #expect(perPage(#"<div style="--filter-width:220px"></div>"#, allowed).count == 1)
        #expect(perPage(#"<div style="display:none; --filter-width:220px"></div>"#, allowed).count == 1)
        #expect(perPage(#"<div style="--bar-h:40%; --filter-width:220px"></div>"#, allowed).count == 1)
        #expect(perPage(#"<div style="--bar-h:40%"></div>"#, allowed).isEmpty)
        #expect(perPage(#"<i style="--av-cap: var(--avatar-cap-plum); --av-border: var(--x)"></i>"#, allowed).isEmpty)

        let orphan = RenderedMarkupRules.orphanSortHeaderViolations
        #expect(orphan(#"<table><tr><th data-sort-type="text">User</th></tr></table>"#).count == 1)
        #expect(orphan(#"<th data-sort-type="text"><span class="sort-icon"></span>User</th>"#).count == 1)
        let wired = #"<th data-sort-type="text"><button class="sort-header" type="button">U</button></th>"#
        #expect(orphan(wired).isEmpty)
        #expect(orphan(#"<th class="col-hide-phone">Plain</th>"#).isEmpty)
    }
}
