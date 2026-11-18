// LoadTest/HTMLScrape.swift
//
// Reads the few values the lecture run needs from a page the server
// rendered: the CSRF token and the kernel boot list. These are the same
// values the browser reads (`ChickadeeUI.getCsrfToken`, the notebook page's
// `data-kernel-assets`), found by the attribute that carries them rather
// than by a pattern over the whole page.

import Foundation

enum HTMLScrape {
    /// The CSRF token: the `csrf-token` meta tag, else the hidden `_csrf`
    /// form field, in the order `ChickadeeUI.getCsrfToken` tries them.
    static func csrfToken(in html: String) -> String? {
        for tag in tags(named: "meta", in: html) where attribute("name", in: tag) == "csrf-token" {
            if let value = attribute("content", in: tag), !value.isEmpty { return value }
        }
        for tag in tags(named: "input", in: html) where attribute("name", in: tag) == "_csrf" {
            if let value = attribute("value", in: tag), !value.isEmpty { return value }
        }
        return nil
    }

    /// The value of the first `data-<name>` attribute on any element.
    static func dataAttribute(_ name: String, in html: String) -> String? {
        let key = "data-" + name
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: ">") else { return nil }
            let tag = afterOpen[..<close]
            if let value = attribute(key, in: tag) { return value }
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        return nil
    }

    /// Every start tag with this element name, without its angle brackets.
    static func tags(named element: String, in html: String) -> [Substring] {
        var found: [Substring] = []
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: ">") else { break }
            let tag = afterOpen[..<close]
            let name = tag.prefix { !$0.isWhitespace && $0 != "/" }
            if name.lowercased() == element { found.append(tag) }
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        return found
    }

    /// One attribute's value inside a start tag, entity-decoded. Values are
    /// quoted with `"` or `'`, as the server's renderer writes them.
    static func attribute(_ name: String, in tag: Substring) -> String? {
        var rest = tag
        while let range = rest.range(of: name + "=") {
            let before = rest[..<range.lowerBound].last
            let valueStart = range.upperBound
            guard before == nil || before?.isWhitespace == true else {
                rest = rest[valueStart...]
                continue
            }
            guard valueStart < rest.endIndex else { return nil }
            let quote = rest[valueStart]
            guard quote == "\"" || quote == "'" else { return nil }
            let body = rest[rest.index(after: valueStart)...]
            guard let end = body.firstIndex(of: quote) else { return nil }
            return decodeEntities(body[..<end])
        }
        return nil
    }

    /// The five entities the server's HTML escaping writes.
    static func decodeEntities(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        return String(
            text
                .replacing("&quot;", with: "\"")
                .replacing("&#39;", with: "'")
                .replacing("&#x27;", with: "'")
                .replacing("&lt;", with: "<")
                .replacing("&gt;", with: ">")
                .replacing("&amp;", with: "&"))
    }
}
