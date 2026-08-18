// Tests/APITests/PageArchetypeTests.swift
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
// have honest variation — `submit.leaf` is a perfectly good plain student page
// with no sections in it at all. It guards the ONE page per archetype the
// rulebook now names as the thing to copy. That is deliberately weaker, and it
// is the whole value of naming an exemplar: "copy `alerts.leaf`" is worth
// saying only for as long as `alerts.leaf` is worth copying.
//
// Three properties this suite holds itself to, each learned the hard way here:
//
//   * DERIVE THE LIST, DO NOT RESTATE IT. The exemplars are read out of the
//     rulebook table, so the documentation and the guard cannot disagree. A
//     second hand-typed list would be a second source of truth, and a
//     documented shape that nothing checks is the problem being fixed.
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
//     rules against every other archetype's exemplar — and fails if any pair
//     comes back clean. A rule refactored into a no-op turns that test red
//     rather than turning this whole file into decoration.

import Foundation
import Testing

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

    /// One page, read both ways.
    ///
    /// `markup` has HTML comments stripped and answers questions about the
    /// page's shape; `source` is verbatim and answers questions about Leaf,
    /// whose lexer does not know what an HTML comment is.
    struct Page {
        let file: String
        let markup: String
        let source: String

        var partials: [String] { LeafMarkupScanner.extendedPartials(in: source) }
        var topHeadings: [LeafMarkupScanner.OpenTag] { LeafMarkupScanner.openTags("h1", in: markup) }

        func declares(_ className: String) -> Bool {
            LeafMarkupScanner.declaresClass(className, in: markup)
        }
    }

    // MARK: - Reading the rulebook

    private static var rulebookURL: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("docs/ui-design.md")
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

    static func page(_ file: String) throws -> Page {
        Page(
            file: file,
            markup: try LeafMarkupScanner.markup(of: file),
            source: try LeafMarkupScanner.source(of: file)
        )
    }

    /// The exemplar page of every archetype the rulebook names.
    static func exemplars() throws -> [(archetype: Archetype, page: Page)] {
        try archetypeRows().compactMap { row in
            guard let archetype = Archetype(rawValue: row.archetypeName) else { return nil }
            return (archetype, try page(row.exemplar))
        }
    }

    // MARK: - The rules

    /// What every exemplar owes whatever its shape. Returns one sentence per
    /// broken rule; empty means it holds.
    static func universalViolations(in page: Page) -> [String] {
        var broken: [String] = []

        if page.partials.first != "base" {
            broken.append("a page extends base.leaf first — that is where the nav and the flash banners live")
        }
        for slot in ["title", "content"] where !page.source.contains("#export(\"\(slot)\")") {
            broken.append("base.leaf imports \(slot); a page that does not export it renders an empty one")
        }

        // base.leaf renders the _flash partial once for every page, so writing
        // those classes in a page is a second copy of something already on
        // screen. The static-state variants (.flash-neutral / .flash-warning)
        // are a different control and stay allowed.
        for banner in ["flash-success", "flash-error"] where page.declares(banner) {
            broken.append(".\(banner) belongs to the _flash partial that base.leaf already renders")
        }

        // "Don't restyle a heading to fake a different level" only means
        // something if the levels are a real spine.
        let levels = LeafMarkupScanner.headingLevels(in: page.markup)
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
        // Each complaint completes the sentence "<file> is the <archetype>
        // exemplar, but …", so they are written as clauses about the page
        // rather than as restatements of the rule.
        func requireSoleTopHeading(inside container: String) {
            let headings = page.topHeadings
            guard headings.count == 1, let heading = headings.first else {
                broken.append("it declares \(headings.count) h1s where this archetype has exactly one")
                return
            }
            let enclosing = LeafMarkupScanner.enclosingOpenTag(before: heading.index, in: page.markup) ?? "nothing"
            require(
                LeafMarkupScanner.tagCarriesClass(container, in: enclosing),
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
            require(page.declares("admin-version-banner"), "it does not open with the .admin-version-banner")
            require(page.partials.contains("_admin-tabs"), "its tab bar is not the _admin-tabs partial")
            requireNoTopHeading("the tab partial already emits this page's — a second is two page titles")
            requireSections()

        case .instructorTabbed:
            require(page.partials.contains("_instructor-tabs"), "its tab bar is not the _instructor-tabs partial")
            requireNoTopHeading("the tab partial already emits this page's — a second is two page titles")
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
                !page.partials.contains("_admin-tabs") && !page.partials.contains("_instructor-tabs"),
                "it carries a tab bar, which is a different archetype"
            )
            requireSections()

        case .authBox:
            require(page.declares("auth-box"), "it has no .auth-box centred card")
            requireSoleTopHeading(inside: "auth-box")
            requireNoSections("the box is the whole page — there is nothing beside it to wrap")

        case .bodyPartialShim:
            require(
                page.partials.count == 2 && page.partials.last?.hasPrefix("_") == true,
                "it does not extend base plus exactly one body partial, which is all a shim is"
            )
            require(
                !page.markup.contains("<"),
                "it owns markup — anything a shim grows belongs in the body partial it extends"
            )

        case .fullBleedApp:
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

    @Test func everyExemplarIsARealDistinctTemplate() throws {
        let rows = try Self.archetypeRows()
        let templates = Set(try LeafMarkupScanner.templateNames())

        for row in rows {
            #expect(
                templates.contains(row.exemplar),
                "\(row.archetypeName): the exemplar \(row.exemplar) is not a template in Resources/Views"
            )
            #expect(
                !row.exemplar.hasPrefix("_"),
                "\(row.archetypeName): \(row.exemplar) is a partial, not a page — an exemplar is a page to copy"
            )
        }
        #expect(
            Set(rows.map(\.exemplar)).count == rows.count,
            "two archetypes name the same exemplar; each shape needs its own reference"
        )
    }

    /// The Also column is where an author looks when the exemplar does not
    /// answer their question, so a name that no longer exists sends them
    /// nowhere.
    @Test func everyPageNamedBesideAnExemplarStillExists() throws {
        let templates = Set(try LeafMarkupScanner.templateNames())
        for row in try Self.archetypeRows() {
            let names = row.alsoColumn
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
                .filter { !$0.isEmpty && $0 != "—" }
            for name in names {
                let file = name.hasSuffix(".leaf") ? name : name + ".leaf"
                #expect(
                    templates.contains(file),
                    "\(row.archetypeName): the Also column names \(name), which is not a template"
                )
            }
        }
    }

    // MARK: - The exemplars themselves

    @Test func everyExemplarObeysTheRulesThatHoldAcrossArchetypes() throws {
        for (_, page) in try Self.exemplars() {
            let complaints = Self.universalViolations(in: page)
            #expect(complaints.isEmpty, "\(page.file): \(complaints.joined(separator: "; and "))")
        }
    }

    @Test func everyExemplarStillMatchesItsOwnArchetype() throws {
        for (archetype, page) in try Self.exemplars() {
            let complaints = Self.violations(of: archetype, in: page)
            #expect(
                complaints.isEmpty,
                """
                \(page.file) is the \(archetype.rawValue) exemplar, but \(complaints.joined(separator: "; and ")).
                Either restore the shape, or name a different page as this archetype's exemplar in \
                docs/ui-design.md — the reference is the file everyone copies, so it going quietly \
                off-shape is how the next new page inherits the drift.
                """
            )
        }
    }

    /// The full-bleed archetype is named for a mechanism in `base.leaf` rather
    /// than for anything visible in the page, so the page alone cannot show
    /// that the mechanism still exists.
    @Test func theFullBleedMechanismStillExistsInTheBaseLayout() throws {
        let base = try LeafMarkupScanner.source(of: "base.leaf")
        #expect(
            base.contains("fullBleed") && base.contains("main-fullbleed"),
            "base.leaf no longer branches on fullBleed — the full-bleed archetype's mechanism is gone"
        )
    }

    // MARK: - The rules, seen to fail

    /// Every archetype's rules against every other archetype's exemplar. Each
    /// of the forty-two pairs must produce at least one complaint.
    ///
    /// This is what stands between the suite and quiet decoration. Every
    /// assertion above is of the form "this list is empty", which an emptied-out
    /// rule satisfies perfectly; the same rule run against a page it should
    /// reject does not.
    @Test func theArchetypeRulesTellTheSevenShapesApart() throws {
        let exemplars = try Self.exemplars()
        #expect(exemplars.count == Archetype.allCases.count, "not every archetype resolved to an exemplar page")

        for (archetype, _) in exemplars {
            for (otherArchetype, otherPage) in exemplars where otherArchetype != archetype {
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

    /// The same demonstration for the rules that are not per-archetype: a page
    /// breaking each of them must be caught.
    @Test func theSharedRulesRejectAPageThatBreaksThem() {
        func synthetic(source: String, markup: String? = nil) -> Page {
            Page(file: "synthetic.leaf", markup: markup ?? source, source: source)
        }
        let wellFormed = "#extend(\"base\"):\n#export(\"title\"):\nT\n#endexport\n#export(\"content\"):\n"

        let cases: [(String, Page)] = [
            (
                "a page that does not extend the base layout",
                synthetic(source: "#export(\"title\"):\nT\n#endexport\n#export(\"content\"):\n<h1>Hi</h1>\n")
            ),
            (
                "a page that exports no content",
                synthetic(source: "#extend(\"base\"):\n#export(\"title\"):\nT\n#endexport\n")
            ),
            (
                "a page hand-rolling the flash banner base.leaf already renders",
                synthetic(source: wellFormed + "<div class=\"flash flash-error\">boom</div>\n")
            ),
            (
                "a page skipping a heading level",
                synthetic(source: wellFormed + "<h1>Title</h1>\n<h3>Buried</h3>\n")
            ),
            (
                "a page whose first heading is below h2",
                synthetic(source: wellFormed + "<h4>Sideways</h4>\n")
            ),
        ]

        for (description, page) in cases {
            #expect(
                !Self.universalViolations(in: page).isEmpty,
                "the shared rules accept \(description) — one of them has stopped checking anything"
            )
        }

        // …and accept a page that breaks none of them, so the demonstration
        // above is not just "these rules reject everything".
        #expect(
            Self.universalViolations(in: synthetic(source: wellFormed + "<h1>Title</h1>\n<h2>Part</h2>\n")).isEmpty,
            "the shared rules reject a page that breaks none of them"
        )
    }
}
