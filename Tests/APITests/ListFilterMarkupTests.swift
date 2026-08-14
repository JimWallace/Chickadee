// Tests/APITests/ListFilterMarkupTests.swift
//
// The list-filter control's markup contract, asserted structurally.
//
// `Public/list-filter.js` derives everything it does from three things a
// template declares: the `.filter-input` class, the `.filter-group` wrapper it
// sits in, and (for a live filter) `data-list-filter` naming its table. When a
// filter departs from that contract nothing fails — it renders, it filters, it
// just quietly behaves differently from every other one. That is exactly how
// five boxes ended up in three widths and two structures after a slice whose
// stated goal was to make them one control.
//
// `scripts/check-styles.sh` guard 4c holds the parts a grep can hold (no
// per-page `--filter-width`; a file's `.filter-group` count covers its
// `.filter-input` count). Counting is a weak proxy for containment, so the
// containment itself is checked here by walking the tag structure: for each
// `.filter-input`, the nearest enclosing open tag must carry `filter-group`.
//
// Walking BACKWARDS from the input and stopping at the first unclosed open tag
// keeps the check local — whatever conditional markup a template has earlier in
// the file cannot throw the result off, which a whole-file tag stack would not
// survive.

import Foundation
import Testing

@testable import APIServer

@Suite struct ListFilterMarkupTests {

    private static var viewsDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Resources/Views")
    }

    /// Elements that never enclose anything, so they are not candidates for
    /// "the tag that encloses this input".
    private static let voidElements: Set<String> = [
        "input", "br", "img", "meta", "link", "hr", "use", "source", "col", "area",
    ]

    private struct FilterInput {
        let file: String
        let tag: String
        let enclosingTag: String?
    }

    // MARK: - Tag walking

    /// The tag name and whether it is a closing tag, for a `<…>` at `index`.
    private static func tagName(at index: String.Index, in html: String) -> (name: String, isClose: Bool)? {
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
    private static func openTagText(at index: String.Index, in html: String) -> String {
        guard let end = html[index...].firstIndex(of: ">") else { return String(html[index...]) }
        return String(html[index...end])
    }

    /// The open tag that encloses the element beginning at `index`.
    ///
    /// Scans backwards counting close tags: a close tag seen on the way back
    /// means the next open tag of any name is its partner, not our parent. The
    /// first open tag reached at depth zero is the enclosing element.
    private static func enclosingOpenTag(before index: String.Index, in html: String) -> String? {
        var depth = 0
        var cursor = index
        while cursor > html.startIndex {
            cursor = html.index(before: cursor)
            guard html[cursor] == "<", let tag = tagName(at: cursor, in: html) else { continue }
            if tag.isClose {
                depth += 1
                continue
            }
            if Self.voidElements.contains(tag.name) { continue }
            let text = openTagText(at: cursor, in: html)
            if text.hasSuffix("/>") { continue }  // self-closing
            if depth == 0 { return text }
            depth -= 1
        }
        return nil
    }

    /// Every `.filter-input` in every template, with the tag that encloses it.
    private static func filterInputs() throws -> [FilterInput] {
        let files = try FileManager.default
            .contentsOfDirectory(at: viewsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "leaf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var found: [FilterInput] = []
        for file in files {
            let html = try String(contentsOf: file, encoding: .utf8)
            var search = html.startIndex
            while let hit = html.range(of: "<input", range: search..<html.endIndex) {
                search = hit.upperBound
                let tag = openTagText(at: hit.lowerBound, in: html)
                guard tag.contains("filter-input") else { continue }
                found.append(
                    FilterInput(
                        file: file.lastPathComponent,
                        tag: tag,
                        enclosingTag: enclosingOpenTag(before: hit.lowerBound, in: html)
                    )
                )
            }
        }
        return found
    }

    // MARK: - Tests

    /// The extractor asserts its own completeness: a parser that silently found
    /// nothing would make every assertion below pass vacuously (#1330's lesson).
    @Test func everyKnownFilterIsFound() throws {
        let inputs = try Self.filterInputs()
        let files = Set(inputs.map(\.file))
        #expect(
            files == [
                "admin-audit.leaf",
                "admin-users.leaf",
                "assignment-submissions.leaf",
                "instructor-activity.leaf",
                "instructor-students.leaf",
            ],
            "the filter-input extractor found \(files.sorted()) — update this list when a page gains or loses a filter"
        )
    }

    @Test func everyFilterInputSitsInAFilterGroup() throws {
        for input in try Self.filterInputs() {
            let enclosing = input.enclosingTag ?? "<nothing>"
            #expect(
                enclosing.contains("filter-group"),
                """
                \(input.file): a .filter-input is enclosed by \(enclosing), not a .filter-group.
                The label and input must wrap as one unit, or a narrow row strands the label.
                """
            )
        }
    }

    /// The component reads `type=search` (native clear affordance, correct
    /// keyboard semantics) and the shared `.form-input` look. Both were once
    /// per-page choices.
    @Test func everyFilterInputIsASearchFieldOnTheSharedLook() throws {
        for input in try Self.filterInputs() {
            #expect(input.tag.contains("type=\"search\""), "\(input.file): a filter must be type=search")
            #expect(input.tag.contains("form-input"), "\(input.file): a filter must carry .form-input")
        }
    }

    /// Autofill suppression is the component's job for every filter, live or
    /// GET-form. A template carrying `autocomplete` is the split that left the
    /// two server-side filters with the weaker half of the suppression.
    @Test func noFilterInputDeclaresAutocompleteInMarkup() throws {
        for input in try Self.filterInputs() {
            #expect(
                !input.tag.contains("autocomplete"),
                "\(input.file): list-filter.js owns autofill suppression — drop the autocomplete attribute"
            )
        }
    }

    /// A live filter names its table; a GET-form filter names none and posts to
    /// the server. Nothing else is a valid filter.
    @Test func everyFilterIsEitherLiveOrInAGetForm() throws {
        let liveFilters = ["admin-users.leaf", "assignment-submissions.leaf", "instructor-students.leaf"]
        for input in try Self.filterInputs() {
            let isLive = input.tag.contains("data-list-filter=")
            #expect(
                isLive == liveFilters.contains(input.file),
                "\(input.file): a filter is live (data-list-filter) or server-side (a GET form), not both or neither"
            )
            if isLive {
                #expect(
                    input.tag.contains("data-list-filter-empty="),
                    "\(input.file): a live filter needs its own no-match wording"
                )
            }
        }
    }
}
