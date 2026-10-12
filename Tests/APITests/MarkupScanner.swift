// Tests/APITests/MarkupScanner.swift
//
// Reading rendered HTML as STRUCTURE, for the markup-contract guards.
//
// Three guards use it — `ListFilterMarkupTests` (the list-filter control's
// shape), `RowMenuMarkupTests` (the row menu's shape) and `PageArchetypeTests`
// (the page archetypes' shape). Each reads the renders in
// `ElementaryPageFixtures`, and each needs the same two things a `grep`
// cannot give it.
//
// 1. CONTAINMENT. "Is this `<h1>` inside the `.page-titlebar`" is a question
//    about the tag tree, and the answer is found by walking BACKWARDS from the
//    match to the first unclosed open tag. Walking back rather than building a
//    whole-document tag stack keeps the answer local, so markup earlier in the
//    page cannot throw it off.
//
// 2. PROSE IS NOT MARKUP. A scanner cannot tell a tag from a sentence about a
//    tag, and this codebase has been bitten by that repeatedly — twice by drift
//    guards that matched their own documentation. Comments are stripped before
//    anything else looks at the markup, so a page that *describes* the markup
//    it must not contain still passes.

import Foundation

enum MarkupScanner {

    /// Elements that never enclose anything, so they are never the answer to
    /// "which tag encloses this one".
    static let voidElements: Set<String> = [
        "input", "br", "img", "meta", "link", "hr", "use", "source", "col", "area",
    ]

    /// Removes `<!-- … -->` spans, including multi-line ones. An unterminated
    /// comment swallows the rest of the text, which is what a browser does too.
    static func strippingHTMLComments(_ source: String) -> String {
        var out = ""
        var cursor = source.startIndex
        while let open = source.range(of: "<!--", range: cursor..<source.endIndex) {
            out += source[cursor..<open.lowerBound]
            guard let close = source.range(of: "-->", range: open.upperBound..<source.endIndex) else {
                return out
            }
            cursor = close.upperBound
        }
        out += source[cursor...]
        return out
    }

    // MARK: - Tag walking

    /// The tag name and whether it closes, for a `<…>` beginning at `index`.
    static func tagName(at index: String.Index, in html: String) -> (name: String, isClose: Bool)? {
        var cursor = html.index(after: index)
        guard cursor < html.endIndex else { return nil }
        var isClose = false
        if html[cursor] == "/" {
            isClose = true
            cursor = html.index(after: cursor)
        }
        var name = ""
        while cursor < html.endIndex, html[cursor].isLetter || html[cursor].isNumber {
            name.append(html[cursor])
            cursor = html.index(after: cursor)
        }
        return name.isEmpty ? nil : (name.lowercased(), isClose)
    }

    /// The full text of the open tag starting at `index` (`<span class="…">`).
    static func openTagText(at index: String.Index, in html: String) -> String {
        guard let end = html[index...].firstIndex(of: ">") else { return String(html[index...]) }
        return String(html[index...end])
    }

    /// The open tag that encloses the element beginning at `index`.
    ///
    /// Scans backwards counting close tags: a close tag seen on the way back
    /// means the next open tag of any name is its partner, not our parent. The
    /// first open tag reached at depth zero is the enclosing element.
    static func enclosingOpenTag(before index: String.Index, in html: String) -> String? {
        var depth = 0
        var cursor = index
        while cursor > html.startIndex {
            cursor = html.index(before: cursor)
            guard html[cursor] == "<", let tag = tagName(at: cursor, in: html) else { continue }
            if tag.isClose {
                depth += 1
                continue
            }
            if voidElements.contains(tag.name) { continue }
            let text = openTagText(at: cursor, in: html)
            if text.hasSuffix("/>") { continue }  // self-closing
            if depth == 0 { return text }
            depth -= 1
        }
        return nil
    }

    // MARK: - Finding elements

    /// One open tag, located.
    struct OpenTag {
        let index: String.Index
        let text: String
    }

    /// Every open tag of `element`, in document order.
    ///
    /// The name must be followed by a delimiter, so asking for `h1` does not
    /// also answer with `h1x`, and asking for `section` does not match `sect`.
    static func openTags(_ element: String, in html: String) -> [OpenTag] {
        var found: [OpenTag] = []
        var search = html.startIndex
        while let hit = html.range(of: "<" + element, options: .caseInsensitive, range: search..<html.endIndex) {
            search = hit.upperBound
            let next = hit.upperBound < html.endIndex ? html[hit.upperBound] : ">"
            guard next == ">" || next == "/" || next.isWhitespace else { continue }
            found.append(OpenTag(index: hit.lowerBound, text: openTagText(at: hit.lowerBound, in: html)))
        }
        return found
    }

    /// Heading levels in document order — `[1, 2, 2]` for an `<h1>` followed by
    /// two `<h2>`s. Used to assert a page's heading spine without caring what
    /// the headings say.
    static func headingLevels(in html: String) -> [Int] {
        (1...6)
            .flatMap { level in openTags("h\(level)", in: html).map { (index: $0.index, level: level) } }
            .sorted { $0.index < $1.index }
            .map(\.level)
    }

    /// Whether the markup declares an element carrying `className`.
    ///
    /// Matches the class as a whole word inside a `class="…"` attribute, so
    /// `.page-section` is not answered by `.page-section-header`.
    static func declaresClass(_ className: String, in html: String) -> Bool {
        !elementsCarrying(className, in: html).isEmpty
    }

    /// Every open tag whose `class` attribute carries `className` as a whole word.
    static func elementsCarrying(_ className: String, in html: String) -> [OpenTag] {
        var found: [OpenTag] = []
        var search = html.startIndex
        while let hit = html.range(of: "<", range: search..<html.endIndex) {
            search = hit.upperBound
            guard let tag = tagName(at: hit.lowerBound, in: html), !tag.isClose else { continue }
            let text = openTagText(at: hit.lowerBound, in: html)
            if tagCarriesClass(className, in: text) {
                found.append(OpenTag(index: hit.lowerBound, text: text))
            }
        }
        return found
    }

    /// Whether one open tag's `class` attribute carries `className` as a whole
    /// word.
    static func tagCarriesClass(_ className: String, in openTag: String) -> Bool {
        guard let attr = openTag.range(of: "class=\"") else { return false }
        guard let end = openTag[attr.upperBound...].firstIndex(of: "\"") else { return false }
        return openTag[attr.upperBound..<end]
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0 == className }
    }
}
