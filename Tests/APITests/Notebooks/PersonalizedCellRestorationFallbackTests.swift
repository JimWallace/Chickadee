// Tests/APITests/Notebooks/PersonalizedCellRestorationFallbackTests.swift
//
// `PersonalizedCellRestoration.restoreTemplates` puts the `{{name}}` template
// text back into each personalized cell before an author's save. The save
// route tests reach the matched-by-id path. This suite covers the paths they
// do not: input that is not a notebook, a missing or unreadable canonical
// notebook, and the position fallback for cells that have no nbformat id. The
// fallback accepts a canonical cell only when it is a code cell that carries
// every placeholder the tag names.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct PersonalizedCellRestorationFallbackTests {

    private static func notebook(_ cells: String...) -> Data {
        Data(#"{"cells":[\#(cells.joined(separator: ","))],"metadata":{},"nbformat":4}"#.utf8)
    }

    /// A rendered code cell with no id, personalized for `names`.
    private static func taggedCell(_ source: String, names: String) -> String {
        #"{"cell_type":"code","metadata":{"chickadee_personalized":"\#(names)","keep":1},"outputs":["out"],"source":"\#(source)"}"#
    }

    private static func restoredText(_ outcome: PersonalizedCellRestoration.Outcome) throws -> String {
        guard case .restored(let data) = outcome else {
            throw IssueRecorded("Expected a restored notebook, got \(outcome)")
        }
        return try #require(String(bytes: data, encoding: .utf8))
    }

    // MARK: - Nothing to restore

    @Test func inputThatIsNotANotebookIsReturnedUntouched() {
        let bytes = Data("not a notebook".utf8)
        #expect(PersonalizedCellRestoration.restoreTemplates(in: bytes, canonical: nil) == .restored(bytes))
    }

    @Test func aNotebookWithNoTaggedCellIsReturnedUntouched() {
        let bytes = Self.notebook(#"{"cell_type":"code","metadata":{},"source":"x = 1"}"#)
        #expect(PersonalizedCellRestoration.restoreTemplates(in: bytes, canonical: nil) == .restored(bytes))
    }

    // MARK: - No template to restore from

    @Test func withNoCanonicalNotebookEveryTaggedPlaceholderIsReported() {
        let incoming = Self.notebook(
            Self.taggedCell("b = 2", names: "beta,alpha"),
            Self.taggedCell("a = 1", names: "alpha"))
        #expect(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: nil)
                == .unmatched(placeholders: ["alpha", "beta"]))
    }

    @Test func aCanonicalNotebookThatDoesNotParseIsTreatedAsMissing() {
        let incoming = Self.notebook(Self.taggedCell("n = 3", names: "n"))
        #expect(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: Data("{".utf8))
                == .unmatched(placeholders: ["n"]))
    }

    // MARK: - Position fallback for cells with no id

    @Test func aCellWithNoIdIsRestoredFromTheCodeCellAtTheSamePosition() throws {
        let canonical = Self.notebook(
            #"{"cell_type":"markdown","metadata":{},"source":"Title"}"#,
            #"{"cell_type":"code","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = Self.notebook(
            #"{"cell_type":"markdown","metadata":{},"source":"Title"}"#,
            Self.taggedCell("n = 3", names: "n"))

        let text = try Self.restoredText(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical))
        #expect(text.contains("n = {{n}}"))
        #expect(!text.contains("n = 3"))
        // The tag goes; the rest of the author's cell stays.
        #expect(!text.contains("chickadee_personalized"))
        #expect(text.contains(#""keep":1"#))
        #expect(text.contains(#""outputs":["out"]"#))
    }

    @Test func aCellWithNoIdPastTheEndOfTheCanonicalNotebookIsUnmatched() {
        let canonical = Self.notebook(#"{"cell_type":"code","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = Self.notebook(
            #"{"cell_type":"code","metadata":{},"source":"pass"}"#,
            Self.taggedCell("n = 3", names: "n"))
        #expect(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical)
                == .unmatched(placeholders: ["n"]))
    }

    @Test func aCellWithNoIdIsNotRestoredFromAMarkdownCell() {
        let canonical = Self.notebook(#"{"cell_type":"markdown","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = Self.notebook(Self.taggedCell("n = 3", names: "n"))
        #expect(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical)
                == .unmatched(placeholders: ["n"]))
    }

    /// A code cell at the same position that lacks one of the tagged names is
    /// a coincidence of position, not the template.
    @Test func aCellWithNoIdIsNotRestoredFromACellMissingAPlaceholder() {
        let canonical = Self.notebook(#"{"cell_type":"code","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = Self.notebook(Self.taggedCell("n = 3; m = 4", names: "n,m"))
        #expect(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical)
                == .unmatched(placeholders: ["m", "n"]))
    }

    /// An empty id counts as no id, so the position fallback applies.
    @Test func anEmptyIdUsesThePositionFallback() throws {
        let canonical = Self.notebook(#"{"cell_type":"code","id":"","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = Self.notebook(
            #"{"cell_type":"code","id":"","metadata":{"chickadee_personalized":"n"},"source":"n = 3"}"#)
        let text = try Self.restoredText(
            PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical))
        #expect(text.contains("n = {{n}}"))
    }
}
