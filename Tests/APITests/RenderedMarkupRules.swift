// Tests/APITests/RenderedMarkupRules.swift
//
// The UI rules of docs/ui-design.md, applied to rendered HTML instead of to
// template files. The shell guards (check-styles.sh, check-class-resolution.sh,
// check-css-vars.sh, check-ui-vocabulary.sh) read Resources/Views/*.leaf and
// cannot see a Swift view at all; ElementaryPageGuardTests feeds every
// Elementary page through these instead (docs/elementary-spike.md, "Guards").
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
