// Tests/APITests/TestEditorCatalogCoverageTests.swift
//
// The "+ Add Test" menu is a hand-written catalog in `Public/test-editor-modal.js`:
// one entry per `PatternKind` and per `NotebookCheckKind`, plus the custom-script
// entry. Nothing made it cover them.
//
// The consequence of that gap is quiet in the direction that matters. A ninth
// pattern kind lands with a renderer in six languages, a validator, an MCP
// schema and execution tests — every one of which fails loudly if it is
// missing — and then simply does not appear in the menu. The server accepts it,
// an agent can author it, and the instructor sitting in the editor has no way
// to reach it. No error, no red test: the feature ships invisible.
//
// `AuthoringLanguageFactsTests` already pins that the menu's per-language
// AVAILABILITY agrees with the save-time validator (#1290). This pins the prior
// question that one assumes: that the kind is in the menu at all.
//
// It reads the catalog's STRUCTURE rather than searching the file for names —
// a scanner that grepped for `boundary_equality` would be satisfied by the word
// appearing in a comment about it, which is the blindness recorded in CLAUDE.md
// under the Leaf-comment finding.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct TestEditorCatalogCoverageTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // APITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static func modalSource() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Public/test-editor-modal.js"),
            encoding: .utf8)
    }

    /// The text of a top-level `var NAME = <open>` … matching close, found by
    /// walking brackets so a nested literal cannot end the slice early.
    private static func literalBody(
        _ source: String, named name: String, open: Character, close: Character
    ) throws -> String {
        let declaration = "var \(name) = \(open)"
        let start = try #require(
            source.range(of: declaration),
            "\(name) is not declared in test-editor-modal.js")
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            let character = source[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return String(source[start.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        Issue.record("\(name)'s literal is never closed")
        return ""
    }

    /// Every `{ value: '…', mechanism: '…' }` pair in the catalog.
    private static func catalogEntries() throws -> [String: String] {
        let body = try literalBody(try modalSource(), named: "CATALOG", open: "[", close: "]")
        let pattern = try NSRegularExpression(
            pattern: #"\bvalue:\s*'([a-z_]+)'\s*,\s*mechanism:\s*'([a-z]+)'"#)
        let range = NSRange(body.startIndex..., in: body)
        var entries: [String: String] = [:]
        for match in pattern.matches(in: body, range: range) {
            guard let key = Range(match.range(at: 1), in: body),
                let mechanism = Range(match.range(at: 2), in: body)
            else { continue }
            entries[String(body[key])] = String(body[mechanism])
        }
        return entries
    }

    @Test func everyPatternKindIsOfferedInTheAddTestMenu() throws {
        let entries = try Self.catalogEntries()
        #expect(!entries.isEmpty, "no catalog entries were parsed — has the literal's shape changed?")
        for kind in PatternKind.allCases {
            #expect(
                entries[kind.rawValue] == "family",
                """
                PatternKind.\(kind.rawValue) is missing from the Add Test catalog in \
                Public/test-editor-modal.js (or is not registered as a `family`). \
                The server would accept it and an agent could author it, but no instructor \
                could reach it from the editor.
                """)
        }
    }

    @Test func everyNotebookCheckKindIsOfferedInTheAddTestMenu() throws {
        let entries = try Self.catalogEntries()
        for kind in NotebookCheckKind.allCases {
            #expect(
                entries[kind.rawValue] == "check",
                """
                NotebookCheckKind.\(kind.rawValue) is missing from the Add Test catalog in \
                Public/test-editor-modal.js (or is not registered as a `check`).
                """)
        }
    }

    /// Nothing in the menu that the server does not know about. The reverse
    /// direction is the one that fails loudly anyway — an unknown kind is
    /// refused at save — but a stale entry sends the instructor down a path
    /// that ends in a rejection, which is the experience #1290 existed to end.
    @Test func theMenuOffersNothingTheServerWouldRefuse() throws {
        let known = Set(PatternKind.allCases.map(\.rawValue))
            .union(NotebookCheckKind.allCases.map(\.rawValue))
            // The custom-script flow is a mechanism, not a kind.
            .union(["script"])
        for (value, mechanism) in try Self.catalogEntries() {
            #expect(
                known.contains(value),
                """
                the Add Test catalog offers '\(value)' (\(mechanism)), which is not a kind \
                the server knows — saving it would be refused
                """)
        }
    }

    /// BOTH renderings of the catalog consult the per-language support
    /// predicate.
    ///
    /// There are two, and only one used to. The modal's `<select>` disabled a
    /// kind the assignment's language cannot support (#1290); the "+ Add Test"
    /// dropdown built from the same catalog did not — and for a `family` or
    /// `check` kind that dropdown does not open the modal at all, it calls
    /// `chickadeeAddInlineTest` and authors the row in place. So the select's
    /// disabled options guarded a path an instructor no longer takes, and a Lua
    /// author picking "DataFrame has the right shape" went straight to an inline
    /// row for a kind Lua refuses at save time.
    ///
    /// Asserted by reading each function's body rather than by searching the
    /// file: the predicate's name appears in the comments above both of them,
    /// so a whole-file search would have been satisfied by the prose while the
    /// menu stayed unguarded.
    @Test func bothCatalogRenderersConsultTheSupportPredicate() throws {
        let source = try Self.modalSource()
        for function in ["addTestMenuHTML"] {
            let body = try Self.functionBody(source, named: function)
            #expect(
                body.contains("unsupportedReason("),
                """
                \(function) in Public/test-editor-modal.js builds catalog entries without \
                consulting unsupportedReason, so it offers kinds this assignment's language \
                refuses at save time.
                """)
        }
        // The select is built inline rather than in a named function, so it is
        // pinned by the shape of what it emits.
        #expect(
            source.contains("var optionsHTML = CATALOG.map("),
            "the modal's type select is no longer built from CATALOG — re-point this guard")
        #expect(source.contains("var reason = unsupportedReason(it);"))
    }

    /// The body of `function NAME() { … }`, brace-walked so a nested literal
    /// cannot end the slice early.
    private static func functionBody(_ source: String, named name: String) throws -> String {
        let declaration = "function \(name)() {"
        let start = try #require(
            source.range(of: declaration),
            "\(name) is not declared in test-editor-modal.js")
        var depth = 1
        var index = start.upperBound
        var body = ""
        while index < source.endIndex, depth > 0 {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            body.append(character)
            index = source.index(after: index)
        }
        #expect(depth == 0, "\(name)'s body is never closed")
        return body
    }

    /// Every catalog entry has a description. The map is parallel to the
    /// catalog and keyed by the same value, so a kind added to one and not the
    /// other shows an instructor a blank explanation — visibly empty, but only
    /// to whoever happens to open that entry.
    @Test func everyCatalogEntryHasADescription() throws {
        let source = try Self.modalSource()
        let descriptions = try Self.literalBody(
            source, named: "DESCRIPTIONS", open: "{", close: "}")
        let pattern = try NSRegularExpression(pattern: #"(?m)^\s*([a-z_]+):\s*'"#)
        let range = NSRange(descriptions.startIndex..., in: descriptions)
        let described = Set(
            pattern.matches(in: descriptions, range: range).compactMap { match -> String? in
                guard let key = Range(match.range(at: 1), in: descriptions) else { return nil }
                return String(descriptions[key])
            })
        #expect(!described.isEmpty, "no descriptions were parsed — has the literal's shape changed?")
        for value in try Self.catalogEntries().keys.sorted() {
            #expect(
                described.contains(value),
                "the Add Test catalog offers '\(value)' with no entry in DESCRIPTIONS")
        }
    }
}
