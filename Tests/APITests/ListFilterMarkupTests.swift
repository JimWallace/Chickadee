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
// The walk itself lives in `LeafMarkupScanner`, shared with the other
// markup-contract guard rather than copied into it — the duplicate spelling of
// a shared thing being the exact failure the UI vocabulary work is about.

import Foundation
import Testing

@Suite struct ListFilterMarkupTests {

    private struct FilterInput {
        let file: String
        let tag: String
        let enclosingTag: String?
    }

    /// Every `.filter-input` in every template, with the tag that encloses it.
    private static func filterInputs() throws -> [FilterInput] {
        var found: [FilterInput] = []
        for file in try LeafMarkupScanner.templateNames() {
            let html = try LeafMarkupScanner.markup(of: file)
            for tag in LeafMarkupScanner.openTags("input", in: html) {
                guard tag.text.contains("filter-input") else { continue }
                found.append(
                    FilterInput(
                        file: file,
                        tag: tag.text,
                        enclosingTag: LeafMarkupScanner.enclosingOpenTag(before: tag.index, in: html)
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
