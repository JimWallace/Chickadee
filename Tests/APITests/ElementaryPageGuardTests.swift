// Tests/APITests/ElementaryPageGuardTests.swift
//
// The UI guards for Elementary views. The shell guards read only
// Resources/Views/*.leaf, so a page rendered from Swift is invisible to them
// (docs/elementary-spike.md, "Guards"). This suite renders every page in
// ElementaryPageFixtures and holds the HTML to the same rules.

import ChickadeeTestSupport
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
}
