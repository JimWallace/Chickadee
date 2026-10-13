// Tests/APITests/RenderedMarkupRules.swift
//
// The UI rules of docs/ui-design.md, applied to rendered HTML. The shell
// guards (check-styles.sh, check-class-resolution.sh, check-css-vars.sh,
// check-ui-vocabulary.sh) read the Swift view sources, which shows them every
// branch but not a value built at run time or markup split across lines;
// ElementaryPageGuardTests feeds every Elementary page through these rules too
// (docs/elementary-spike.md, "Guards").
//
// Each rule returns one line per violation; empty means the page holds.

import ChickadeeTestSupport
import Foundation

enum RenderedMarkupRules {

    // MARK: - Inline styles (check-styles.sh rule 2)

    /// A `style` attribute may hold only `display:none` or custom-property
    /// assignments. Anything else belongs in a semantic class.
    static func inlineStyleViolations(in html: String) -> [String] {
        attributeValues(named: "style", in: html).filter { value in
            value.split(separator: ";").contains { declaration in
                let compact = declaration.filter { !$0.isWhitespace }
                return !compact.isEmpty && compact != "display:none" && !compact.hasPrefix("--")
            }
        }.map { "style=\"\($0)\"" }
    }

    // MARK: - Per-datum custom properties (check-styles.sh rule 4c, S1)

    /// An inline custom property carries a value that varies per datum (a bar
    /// height, a share, an avatar colour), never a per-page dial such as a
    /// width. `allowed` is `perDatumInlineProperties()`. Every property in the
    /// attribute is checked, wherever it sits (#2404). check-styles.sh reads
    /// the same list for the literals in view source; this also sees a value
    /// held in a variable, such as the avatar's.
    static func perPageInlinePropertyViolations(in html: String, allowed: Set<String>) -> [String] {
        attributeValues(named: "style", in: html).compactMap { value in
            let names = value.matches(of: /(--[A-Za-z0-9_-]+)\s*:/).map { String($0.1) }
            let unlisted = names.filter { !allowed.contains($0) }
            return unlisted.isEmpty ? nil : "style=\"\(value)\" assigns \(unlisted.joined(separator: ", ")) inline"
        }
    }

    /// `PER_DATUM_INLINE_PROPS` in scripts/check-styles.sh: one list for the
    /// source scan and the rendered check.
    static func perDatumInlineProperties() throws -> Set<String> {
        let url = repositoryRoot.appendingPathComponent("scripts/check-styles.sh")
        let script = try String(contentsOf: url, encoding: .utf8)
        guard let line = script.firstMatch(of: /\nPER_DATUM_INLINE_PROPS="([^"]*)"/) else { return [] }
        return Set(line.1.split(separator: " ").map(String.init))
    }

    // MARK: - Sortable headers (check-styles.sh rule 4c, S2)

    /// A `th` that declares `data-sort-type` holds the shared
    /// `button.sort-header`, or it is decorative markup that sorts nothing.
    static func orphanSortHeaderViolations(in html: String) -> [String] {
        html.matches(of: /<th(\s[^>]*)?>([\s\S]*?)<\/th>/).compactMap { match in
            guard let attributes = match.1, attributes.contains(" data-sort-type=\"") else { return nil }
            let hasButton = match.2.contains(/<button[^>]*\sclass="([^"]* )?sort-header( [^"]*)?"/)
            return hasButton ? nil : "<th\(attributes)> has no button.sort-header"
        }
    }

    // MARK: - Scripts (check-styles.sh rules 3b, 3b-2 and 3b-3)

    /// The CSP permits no inline execution: a script loads from `src` or is a
    /// JSON data island, and no element carries an `on*` handler attribute.
    static func scriptViolations(in html: String) -> [String] {
        var broken: [String] = []
        for tag in openTags(named: "script", in: html)
        where !tag.contains(" src=\"") && !tag.contains("type=\"application/json\"") {
            broken.append("inline script: \(tag)")
        }
        for match in html.matches(of: /<[a-zA-Z][^>]*\s(on[a-z]+)\s*=/) {
            broken.append("event handler attribute \(match.1)")
        }
        return broken
    }

    // MARK: - Class resolution (check-class-resolution.sh)

    /// Every assigned class resolves to a rule in `Public/*.css` or in the
    /// page's own `<style>` block, takes the `js-` prefix, or is on the
    /// shrink-only allowlist. `defined` is `resolvableClasses()`.
    static func unresolvedClasses(in html: String, defined: Set<String>) -> [String] {
        let pageDefined = definedClasses(inCSS: styleBlocks(in: html).joined(separator: "\n"))
        let allowed = defined.union(pageDefined)
        let assigned = Set(
            attributeValues(named: "class", in: html).flatMap { $0.split(separator: " ").map(String.init) })
        return assigned.filter { !$0.hasPrefix("js-") && !allowed.contains($0) }.sorted()
    }

    /// The class names `Public/*.css` defines, plus the allowlist.
    static func resolvableClasses() throws -> Set<String> {
        definedClasses(inCSS: try stylesheetText()).union(try classAllowlist())
    }

    // MARK: - CSS variables (check-css-vars.sh)

    /// Every `var(--x)` in a page block or a `style` attribute names a custom
    /// property the stylesheet declares, with no hardcoded fallback. A fallback
    /// that is itself a `var()` is allowed. Stricter than check-css-vars.sh,
    /// which flags only a hex fallback; this is the CLAUDE.md wording.
    static func cssVariableViolations(in html: String, declared: Set<String>) -> [String] {
        let css = stripCSSComments(
            (styleBlocks(in: html) + attributeValues(named: "style", in: html)).joined(separator: "\n"))
        return css.matches(of: /var\(\s*(--[a-zA-Z0-9_-]+)\s*(,\s*(var\()?)?/).compactMap { match in
            if match.2 != nil, match.3 == nil { return "var(\(match.1), …) carries a hardcoded fallback" }
            return declared.contains(String(match.1)) ? nil : "var(\(match.1)) is not declared"
        }
    }

    /// The custom properties `Public/*.css` declares.
    static func declaredCustomProperties() throws -> Set<String> {
        let css = stripCSSComments(try stylesheetText())
        return Set(css.matches(of: /(--[a-zA-Z0-9_-]+)\s*:/).map { String($0.1) })
    }

    // MARK: - Hover text (check-ui-vocabulary.sh rule 3)

    static let titleWordCap = 20

    /// A `title` attribute is hover-only, so it stays short.
    static func longTitles(in html: String) -> [String] {
        attributeValues(named: "title", in: html).compactMap { value in
            let words = value.split(whereSeparator: \.isWhitespace).count
            return words > titleWordCap ? "\(words) words: \(value)" : nil
        }
    }

    // MARK: - Admin tabbed pages (PageArchetypeTests, the AdminTabs component)

    /// The floor every admin tabbed page stands on, read from `<main>`: the
    /// version banner, then the one hidden h1, then the one tab bar, all from
    /// `AdminTabs`, before any section. A page has no partials to read, so
    /// this checks what the component renders.
    static func adminTabbedViolations(in main: String) -> [String] {
        var broken: [String] = []
        let banners = main.ranges(of: #"<p class="admin-version-banner">"#)
        let navs = main.ranges(of: #"<nav class="admin-tabs""#)
        let headings = openTags(named: "h1", in: main)
        if banners.count != 1 { broken.append("\(banners.count) version banners where AdminTabs renders one") }
        if navs.count != 1 { broken.append("\(navs.count) admin tab bars where AdminTabs renders one") }
        if headings != [#"<h1 class="visually-hidden">"#] {
            broken.append("its h1s are \(headings); the only h1 is the hidden one AdminTabs renders")
        }
        if let banner = banners.first, let nav = navs.first {
            if banner.lowerBound > nav.lowerBound { broken.append("the version banner comes after the tab bar") }
            if let section = main.range(of: "<section"), section.lowerBound < nav.lowerBound {
                broken.append("a section comes before the tab bar")
            }
        }
        return broken
    }

    /// The floor every instructor tabbed page stands on, read from `<main>`:
    /// the one hidden h1, then the one tab bar, both from `InstructorTabs`,
    /// before any section.
    static func instructorTabbedViolations(in main: String) -> [String] {
        var broken: [String] = []
        let navs = main.ranges(of: #"<nav class="instructor-tabs""#)
        let headings = openTags(named: "h1", in: main)
        if navs.count != 1 { broken.append("\(navs.count) instructor tab bars where InstructorTabs renders one") }
        if headings != [#"<h1 class="visually-hidden">"#] {
            broken.append("its h1s are \(headings); the only h1 is the hidden one InstructorTabs renders")
        }
        if let nav = navs.first, let section = main.range(of: "<section"), section.lowerBound < nav.lowerBound {
            broken.append("a section comes before the tab bar")
        }
        return broken
    }

    // MARK: - Reading markup

    /// The contents of `<main>`: the part of the page an archetype describes.
    static func mainContent(of html: String) -> String? {
        guard let open = html.firstMatch(of: /<main[^>]*>/), let close = html.range(of: "</main>") else {
            return nil
        }
        return String(html[open.range.upperBound..<close.lowerBound])
    }

    static func styleBlocks(in html: String) -> [String] {
        html.matches(of: /<style[^>]*>([\s\S]*?)<\/style>/).map { String($0.1) }
    }

    /// The values of every `name="…"` attribute. Elementary always double-quotes
    /// and escapes `"` inside a value, so a value never contains one.
    static func attributeValues(named name: String, in html: String) -> [String] {
        var values: [String] = []
        var rest = html[...]
        let needle = " \(name)=\""
        while let start = rest.range(of: needle) {
            let valueStart = start.upperBound
            guard let end = rest[valueStart...].firstIndex(of: "\"") else { break }
            values.append(String(rest[valueStart..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return values
    }

    /// The opening tags of the elements directly inside `main`, in order. The
    /// contents of a script or style element are skipped, and a void element
    /// opens no level.
    static func topLevelOpenTags(in main: String) -> [String] {
        // HTML void elements only. Elementary closes every SVG element, `use`
        // included, so none of them is void here.
        let voids: Set<String> = ["area", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source"]
        var depth = 0
        var tags: [String] = []
        var rest = main[...]
        while let match = rest.firstMatch(of: /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)[^>]*?(\/?)>/) {
            let name = match.2.lowercased()
            let tag = String(match.0)
            rest = rest[match.range.upperBound...]
            if match.1.isEmpty {
                if depth == 0 { tags.append(tag) }
                if name == "script" || name == "style", let end = rest.range(of: "</\(name)>") {
                    rest = rest[end.upperBound...]
                    continue
                }
                if match.3.isEmpty && !voids.contains(name) { depth += 1 }
            } else {
                depth -= 1
            }
        }
        return tags
    }

    /// Stops at the first `>`, which is safe on Elementary output: it escapes
    /// `>` inside an attribute value.
    static func openTags(named name: String, in html: String) -> [String] {
        html.matches(of: /<([a-zA-Z][a-zA-Z0-9]*)(\s[^>]*)?>/).compactMap { match in
            match.1.lowercased() == name ? String(match.0) : nil
        }
    }

    // MARK: - Private

    private static func stylesheetText() throws -> String {
        let publicDirectory = repositoryRoot.appendingPathComponent("Public")
        let sheets = try FileManager.default.contentsOfDirectory(atPath: publicDirectory.path)
            .filter { $0.hasSuffix(".css") }
            .sorted()
        return try sheets.map {
            try String(contentsOf: publicDirectory.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
    }

    private static func definedClasses(inCSS css: String) -> Set<String> {
        Set(stripCSSComments(css).matches(of: /\.([a-z][a-z0-9-]*)/).map { String($0.1) })
    }

    private static func stripCSSComments(_ css: String) -> String {
        css.replacing(/\/\*[\s\S]*?\*\//, with: "")
    }

    /// `scripts/class-resolution-allowlist.txt`, the same shrink-only list the
    /// shell guard reads.
    private static func classAllowlist() throws -> Set<String> {
        let url = repositoryRoot.appendingPathComponent("scripts/class-resolution-allowlist.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(
            text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }
}
