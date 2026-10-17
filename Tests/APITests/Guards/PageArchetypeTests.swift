// Tests/APITests/Guards/PageArchetypeTests.swift
//
// The page archetypes' exemplars, asserted structurally.
//
// `docs/ui-design.md` has defined seven page archetypes for a long time, and
// CLAUDE.md asserts "Pages follow a named archetype" as though something
// enforced it. Nothing did: `archetype` appeared nowhere under `scripts/` or
// `Tests/`, and the only mechanism the rulebook could cite was
// `PAGE_STYLE_BASELINE`, which counts CSS lines and knows nothing about shape.
// The most-repeated UI concept in the rulebook was its least enforced.
//
// This does not close that by guarding every page. A guard that failed a page
// for not matching a skeleton would be a new way to be wrong, and the shapes
// have honest variation — `SubmitPage` is a perfectly good plain student page
// with no sections in it at all. It guards the ONE page per archetype the
// rulebook now names as the thing to copy. That is deliberately weaker, and it
// is the whole value of naming an exemplar: "copy `AlertsPage`" is worth
// saying only for as long as `AlertsPage` is worth copying.
//
// Every page is an Elementary view, so the rules read what a page RENDERS:
// each exemplar's renders in `ElementaryPageFixtures`, cut down to `<main>`.
// The layout chrome around `<main>` is `BaseLayout`'s, and the rules that
// concern the layout read the whole document.
//
// Three properties this suite holds itself to, each learned the hard way here:
//
//   * DERIVE THE LIST, DO NOT RESTATE IT. The exemplars are read out of the
//     rulebook table, so the documentation and the guard cannot disagree. A
//     second hand-typed list would be a second source of truth, and a
//     documented shape that nothing checks is the problem being fixed. The
//     fixtures' `isExemplar` flags are checked against the table in both
//     directions for the same reason.
//
//   * A DERIVATION MUST ASSERT ITS OWN COMPLETENESS. #1330's lesson: a parser
//     that silently finds nothing, or six rows of seven, makes every assertion
//     below pass vacuously and is indistinguishable from a correct one. The
//     table parse is checked against an enum the compiler forces to be
//     exhaustive, in BOTH directions — a row with no case and a case with no
//     row each fail.
//
//   * A CHECK NEVER SEEN TO FAIL IS NOT A CHECK (#1448). The rules are pure
//     functions from a page to the list of ways it breaks them, so they can be
//     run against pages that SHOULD break them. `theArchetypeRulesTellTheSeven
//     ShapesApart` runs all forty-two off-diagonal pairs — every archetype's
//     rules against every render of every other archetype's exemplar — and
//     fails if any pair comes back clean. A rule refactored into a no-op turns
//     that test red rather than turning this whole file into decoration.

import ChickadeeTestSupport
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct PageArchetypeTests {

    /// The seven shapes. The raw value is the archetype's name in the rulebook
    /// table; the switch in `violations(of:in:)` is what makes adding a case
    /// here a compile error until its rules are written.
    enum Archetype: String, CaseIterable {
        case adminTabbed = "Admin tabbed"
        case instructorTabbed = "Instructor tabbed"
        case titlebarPage = "Titlebar page"
        case plainStudentPage = "Plain student page"
        case authBox = "Auth box"
        case bodyPartialShim = "Body-partial shim"
        case fullBleedApp = "Full-bleed app"
    }

    struct Row {
        let archetypeName: String
        let skeleton: String
        let exemplar: String
        let alsoColumn: String
    }

    /// One render of a page, read three ways.
    ///
    /// `document` is the whole render, for the rules about the layout around
    /// the page. `main` is the contents of `<main>` with HTML comments
    /// stripped, for the rules about the page's content. `markup` is what the
    /// page itself owns: `main` without the layout's flash-banner slot and
    /// without the shared body views it embeds (`bodies`, rendered on their
    /// own by the fixture). A Leaf page's own markup was its template file,
    /// and a partial's markup lived in the partial; `markup` is the same cut,
    /// made on the render.
    struct Page {
        let file: String
        let document: String
        let main: String
        let bodies: [String]

        init(file: String, document: String, bodies: [String] = []) {
            self.file = file
            self.document = document
            self.main = MarkupScanner.strippingHTMLComments(RenderedMarkupRules.mainContent(of: document) ?? "")
            self.bodies = bodies.map(MarkupScanner.strippingHTMLComments)
        }

        /// `main` after the flash banners `BaseLayout` renders at its top.
        var mainAfterFlashSlot: String {
            main.replacing(PageArchetypeTests.layoutFlashSlot, with: "")
        }

        /// The bodies this render was said to embed but does not contain.
        var missingBodies: [String] {
            bodies.filter { !main.contains($0) }
        }

        /// What the page owns: `main` without the flash slot and the bodies.
        var markup: String {
            bodies.reduce(mainAfterFlashSlot) { rest, body in
                guard let range = rest.range(of: body) else { return rest }
                return rest.replacingCharacters(in: range, with: "")
            }
        }

        /// The `<main>` open tag `BaseLayout` writes, or nil.
        var mainTag: String? {
            MarkupScanner.openTags("main", in: document).first?.text
        }

        var topHeadings: [MarkupScanner.OpenTag] { MarkupScanner.openTags("h1", in: markup) }

        func declares(_ className: String) -> Bool {
            MarkupScanner.declaresClass(className, in: markup)
        }
    }

    /// The banners `BaseLayout` renders at the top of `<main>` from its
    /// `FlashMessages`. The text inside a banner is escaped, so it holds no `<`.
    static var layoutFlashSlot: Regex<Substring> {
        /^\s*(?:<div class="flash flash-(?:success|error)" role="(?:status|alert)">[^<]*<\/div>\s*)+/
    }

    // MARK: - Reading the rulebook

    private static var rulebookURL: URL {
        repositoryRoot.appendingPathComponent("docs/ui-design.md")
    }

    /// The rows of the archetype table, in document order.
    ///
    /// Finds the table by its heading rather than by position, and stops at the
    /// first non-row line once inside it, so prose added around the table does
    /// not move the parse.
    static func archetypeRows() throws -> [Row] {
        let doc = try String(contentsOf: rulebookURL, encoding: .utf8)
        let lines = doc.components(separatedBy: .newlines)
        guard let headingIndex = lines.firstIndex(where: { $0.hasPrefix("## Page archetypes") }) else {
            return []
        }

        var rows: [Row] = []
        var insideTable = false
        for line in lines[(headingIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }  // the next section; the table is behind us
            guard trimmed.hasPrefix("|") else {
                if insideTable { break }
                continue
            }
            insideTable = true

            let cells =
                trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 4 else { continue }
            if cells[0].hasPrefix("---") || cells[0] == "Archetype" { continue }  // header and rule

            rows.append(
                Row(
                    archetypeName: cells[0].replacingOccurrences(of: "*", with: ""),
                    skeleton: cells[1],
                    exemplar: cells[2].replacingOccurrences(of: "`", with: ""),
                    alsoColumn: cells[3]
                )
            )
        }
        return rows
    }

    /// The names in a row's Also column.
    static func alsoNames(in row: Row) -> [String] {
        row.alsoColumn
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
            .filter { !$0.isEmpty && $0 != "—" }
    }

    /// Every render of a fixture, as pages.
    static func pages(of fixture: ElementaryPageFixture) -> [Page] {
        fixture.renders.enumerated().map { index, html in
            Page(
                file: fixture.typeName, document: html,
                bodies: index < fixture.bodies.count ? fixture.bodies[index] : [])
        }
    }

    /// The exemplar of every archetype the rulebook names, with every render
    /// its fixture holds.
    static func exemplars() throws -> [(archetype: Archetype, pages: [Page])] {
        let fixtures = ElementaryPageFixtures.all
        return try archetypeRows().compactMap { row in
            guard let archetype = Archetype(rawValue: row.archetypeName),
                let fixture = fixtures.first(where: { $0.typeName == row.exemplar })
            else { return nil }
            return (archetype, pages(of: fixture))
        }
    }

    // MARK: - The rules

    /// What every exemplar owes whatever its shape. Returns one sentence per
    /// broken rule; empty means it holds.
    static func universalViolations(in page: Page) -> [String] {
        var broken: [String] = []

        let isLayout =
            page.document.hasPrefix("<!DOCTYPE html>")
            && page.mainTag.map { MarkupScanner.tagCarriesClass("main", in: $0) && $0.contains(#"id="main-content""#) }
                == true
        if !isLayout {
            broken.append("a page renders inside BaseLayout — that is where the nav and the flash banners live")
        }
        let titled = page.document.firstMatch(of: /<title>(.*) — Chickadee<\/title>/).map { !$0.1.isEmpty } == true
        if !titled {
            broken.append("BaseLayout titles the document from the page; this one has no title of its own")
        }
        if page.mainAfterFlashSlot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            broken.append("its <main> is empty, so the page renders no content")
        }

        // BaseLayout renders the flash banners once for every page, at the top
        // of <main>, so those classes anywhere else are a second copy of
        // something already on screen. The static-state variants
        // (.flash-neutral / .flash-warning) are a different control and stay
        // allowed.
        for banner in ["flash-success", "flash-error"]
        where MarkupScanner.declaresClass(banner, in: page.mainAfterFlashSlot) {
            broken.append(".\(banner) belongs to the flash banners BaseLayout already renders")
        }

        // "Don't restyle a heading to fake a different level" only means
        // something if the levels are a real spine.
        let levels = MarkupScanner.headingLevels(in: page.main)
        if let first = levels.first, first > 2 {
            broken.append("the first heading is an h\(first) — a page starts at h1, or at h2 when it is tabbed")
        }
        for (previous, next) in zip(levels, levels.dropFirst()) where next > previous + 1 {
            broken.append("an h\(previous) is followed by an h\(next), skipping a level")
        }

        return broken
    }

    /// Every way `page` fails to be `archetype`. Empty means it matches.
    ///
    /// Exhaustive by construction: an eighth case cannot join `Archetype`
    /// without answering this switch.
    static func violations(of archetype: Archetype, in page: Page) -> [String] {
        var broken: [String] = []

        func require(_ held: Bool, _ complaint: @autoclosure () -> String) {
            if !held { broken.append(complaint()) }
        }
        // Each complaint completes the sentence "<page> is the <archetype>
        // exemplar, but …", so they are written as clauses about the page
        // rather than as restatements of the rule.
        func requireSoleTopHeading(inside container: String) {
            let headings = page.topHeadings
            guard headings.count == 1, let heading = headings.first else {
                broken.append("it declares \(headings.count) h1s where this archetype has exactly one")
                return
            }
            let enclosing = MarkupScanner.enclosingOpenTag(before: heading.index, in: page.markup) ?? "nothing"
            require(
                MarkupScanner.tagCarriesClass(container, in: enclosing),
                "its h1 sits in \(enclosing), not in the .\(container) this archetype puts it in"
            )
        }
        func requireNoTopHeading(_ because: String) {
            require(page.topHeadings.isEmpty, "it declares an h1 of its own, and \(because)")
        }
        func requireSections() {
            require(page.declares("page-section"), "its content is no longer grouped in .page-section blocks")
        }
        func requireNoSections(_ because: String) {
            require(!page.declares("page-section"), "it declares a .page-section, and \(because)")
        }

        switch archetype {
        case .adminTabbed:
            // The banner, the hidden h1 and the tab bar, all from AdminTabs.
            broken += RenderedMarkupRules.adminTabbedViolations(in: page.markup)
            requireSections()

        case .instructorTabbed:
            // The hidden h1 and the tab bar, both from InstructorTabs.
            broken += RenderedMarkupRules.instructorTabbedViolations(in: page.markup)
            requireSections()

        case .titlebarPage:
            require(page.declares("page-titlebar"), "it has no .page-titlebar to head the page with")
            requireSoleTopHeading(inside: "page-titlebar")
            require(
                page.declares("page-subtitle"),
                "it no longer shows the optional .page-subtitle, which is the reason it is this archetype's reference"
            )
            requireSections()

        case .plainStudentPage:
            require(
                page.topHeadings.count == 1,
                "it declares \(page.topHeadings.count) h1s where a plain page has exactly one"
            )
            require(!page.declares("page-titlebar"), "it declares a .page-titlebar, which is a different archetype")
            require(
                !page.declares("admin-tabs") && !page.declares("instructor-tabs"),
                "it carries a tab bar, which is a different archetype"
            )
            requireSections()

        case .authBox:
            require(page.declares("auth-box"), "it has no .auth-box centred card")
            requireSoleTopHeading(inside: "auth-box")
            requireNoSections("the box is the whole page — there is nothing beside it to wrap")

        case .bodyPartialShim:
            // A shim is BaseLayout around exactly one shared body view: its
            // <main>, less the layout's flash banners, is that body's own
            // render and nothing else.
            require(
                page.bodies.count == 1 && page.missingBodies.isEmpty,
                "it does not render BaseLayout around exactly one body view, which is all a shim is"
            )
            require(
                !page.markup.contains("<"),
                "it owns markup — anything a shim grows belongs in the body view it wraps"
            )

        case .fullBleedApp:
            require(
                page.mainTag.map { MarkupScanner.tagCarriesClass("main-fullbleed", in: $0) } == true,
                "BaseLayout does not give it the viewport-owning .main-fullbleed main element"
            )
            requireNoTopHeading("a page that owns the viewport has no page frame to title")
            require(
                !page.declares("page-titlebar"),
                "it declares a .page-titlebar, and a full-bleed page owns the viewport rather than sitting in the page frame"
            )
            requireNoSections("a full-bleed page owns the viewport rather than sitting in the page frame")
            require(
                page.markup.contains("<"),
                "it owns no markup at all, which makes it a body-partial shim rather than an app"
            )
        }

        return broken
    }

    // MARK: - Completeness of the parse

    /// A partial parse is indistinguishable from a correct one once the
    /// assertions below start iterating it, which is exactly how a derived
    /// guard went silently half-blind the last time one was written here.
    @Test func theTableParseCoversEveryArchetypeAndNothingElse() throws {
        let rows = try Self.archetypeRows()
        let named = Set(rows.map(\.archetypeName))
        let known = Set(Archetype.allCases.map(\.rawValue))

        #expect(
            named == known,
            """
            the archetype table in docs/ui-design.md parsed to \(named.sorted()),
            but this suite knows \(known.sorted()).
            A row with no case here, or a case with no row there, means one of the two moved.
            An eighth archetype is a conversation (docs/ui-design.md says so), not a row.
            """
        )
        #expect(rows.count == Archetype.allCases.count, "the archetype table has a duplicate row")
    }

    /// Each exemplar is a page type with a fixture. `ElementaryPageGuardTests`
    /// holds the fixtures equal to the files under `Views/Pages/`, so a body
    /// view such as `AssignmentEditBody` cannot be named: an exemplar is a page
    /// to copy, not a part of one.
    @Test func everyExemplarIsARealDistinctPage() throws {
        let rows = try Self.archetypeRows()
        let fixtures = ElementaryPageFixtures.all

        for row in rows {
            let fixture = fixtures.first { $0.typeName == row.exemplar }
            #expect(
                fixture != nil,
                "\(row.archetypeName): the exemplar \(row.exemplar) is not a page type in ElementaryPageFixtures"
            )
            if let fixture {
                #expect(
                    fixture.archetype.rawValue == row.archetypeName,
                    "\(row.exemplar) is the \(row.archetypeName) exemplar, but its fixture says \(fixture.archetype.rawValue)"
                )
            }
        }
        #expect(
            Set(rows.map(\.exemplar)).count == rows.count,
            "two archetypes name the same exemplar; each shape needs its own reference"
        )
        // The flag the guard suite reads, and the table, name the same pages.
        #expect(
            Set(fixtures.filter(\.isExemplar).map(\.typeName)) == Set(rows.map(\.exemplar)),
            "the fixtures marked isExemplar are not the pages docs/ui-design.md names as exemplars"
        )
    }

    /// The Also column is where an author looks when the exemplar does not
    /// answer their question, so a name that no longer exists sends them
    /// nowhere.
    @Test func everyPageNamedBesideAnExemplarStillExists() throws {
        let pageTypes = Set(ElementaryPageFixtures.all.map(\.typeName))
        for row in try Self.archetypeRows() {
            for name in Self.alsoNames(in: row) {
                #expect(
                    pageTypes.contains(name),
                    "\(row.archetypeName): the Also column names \(name), which is not a page type"
                )
            }
        }
    }

    // MARK: - The exemplars themselves

    @Test func everyExemplarObeysTheRulesThatHoldAcrossArchetypes() throws {
        for (_, pages) in try Self.exemplars() {
            for page in pages {
                let complaints = Self.universalViolations(in: page)
                #expect(complaints.isEmpty, "\(page.file): \(complaints.joined(separator: "; and "))")
            }
        }
    }

    @Test func everyExemplarStillMatchesItsOwnArchetype() throws {
        for (archetype, pages) in try Self.exemplars() {
            for page in pages {
                let complaints = Self.violations(of: archetype, in: page)
                #expect(
                    complaints.isEmpty,
                    """
                    \(page.file) is the \(archetype.rawValue) exemplar, but \(complaints.joined(separator: "; and ")).
                    Either restore the shape, or name a different page as this archetype's exemplar in \
                    docs/ui-design.md — the reference is the page everyone copies, so it going quietly \
                    off-shape is how the next new page inherits the drift.
                    """
                )
            }
        }
    }

    /// The full-bleed archetype is named for a mechanism in `BaseLayout`
    /// rather than for anything the page writes. The full-bleed rule reads the
    /// mechanism's output on the exemplar; this shows that the flag, and only
    /// the flag, produces it.
    @Test func theFullBleedMechanismStillExistsInTheBaseLayout() {
        let page = ElementaryPageFixtures.page()
        let fullBleed = Page(
            file: "full-bleed", document: BaseLayout(title: "T", page: page, fullBleed: true) { div {} }.render())
        let framed = Page(file: "framed", document: BaseLayout(title: "T", page: page) { div {} }.render())
        #expect(
            fullBleed.mainTag.map { MarkupScanner.tagCarriesClass("main-fullbleed", in: $0) } == true,
            "BaseLayout no longer gives a full-bleed page the viewport-owning main element"
        )
        #expect(
            framed.mainTag.map { MarkupScanner.tagCarriesClass("main-fullbleed", in: $0) } == false,
            "BaseLayout gives every page the full-bleed main element, so the flag no longer means anything"
        )
    }

    // MARK: - The rules, seen to fail

    /// Every archetype's rules against every render of every other archetype's
    /// exemplar. Each of the forty-two pairs must produce at least one
    /// complaint on each render.
    ///
    /// This is what stands between the suite and quiet decoration. Every
    /// assertion above is of the form "this list is empty", which an emptied-out
    /// rule satisfies perfectly; the same rule run against a page it should
    /// reject does not.
    @Test func theArchetypeRulesTellTheSevenShapesApart() throws {
        let exemplars = try Self.exemplars()
        #expect(exemplars.count == Archetype.allCases.count, "not every archetype resolved to an exemplar page")

        for (archetype, _) in exemplars {
            for (otherArchetype, otherPages) in exemplars where otherArchetype != archetype {
                #expect(!otherPages.isEmpty, "the \(otherArchetype.rawValue) exemplar has no renders")
                for otherPage in otherPages {
                    #expect(
                        !Self.violations(of: archetype, in: otherPage).isEmpty,
                        """
                        the \(archetype.rawValue) rules accept \(otherPage.file), which is the \
                        \(otherArchetype.rawValue) exemplar. Two archetypes this guard cannot tell apart \
                        means one of them is no longer checking anything that distinguishes it.
                        """
                    )
                }
            }
        }
    }

    /// The same demonstration for the rules that are not per-archetype: a page
    /// breaking each of them must be caught.
    @Test func theSharedRulesRejectAPageThatBreaksThem() {
        func layout(flash: FlashMessages = FlashMessages(), @HTMLBuilder _ content: () -> some HTML) -> Page {
            Page(
                file: "synthetic",
                document: BaseLayout(title: "T", page: ElementaryPageFixtures.page(), flash: flash, content: content)
                    .render())
        }

        let cases: [(String, Page)] = [
            (
                "a page that does not render inside the base layout",
                Page(file: "synthetic", document: "<!DOCTYPE html><html><body><main><h1>Hi</h1></main></body></html>")
            ),
            (
                "a page that renders no content",
                layout { EmptyHTML() }
            ),
            (
                "a page hand-rolling the flash banner BaseLayout already renders",
                layout {
                    h1 { "Title" }
                    div(.class("flash flash-error"), .role("alert")) { "boom" }
                }
            ),
            (
                "a page skipping a heading level",
                layout {
                    h1 { "Title" }
                    h3 { "Buried" }
                }
            ),
            (
                "a page whose first heading is below h2",
                layout { h4 { "Sideways" } }
            ),
        ]

        for (description, page) in cases {
            #expect(
                !Self.universalViolations(in: page).isEmpty,
                "the shared rules accept \(description) — one of them has stopped checking anything"
            )
        }

        // …and accept a page that breaks none of them, with and without the
        // layout's own banners, so the demonstration above is not just "these
        // rules reject everything".
        for flash in [FlashMessages(), FlashMessages(success: "Saved.", error: "But not that.")] {
            let wellFormed = layout(flash: flash) {
                h1 { "Title" }
                h2 { "Part" }
            }
            #expect(
                Self.universalViolations(in: wellFormed).isEmpty,
                "the shared rules reject a page that breaks none of them: \(Self.universalViolations(in: wellFormed))"
            )
        }
    }
}
