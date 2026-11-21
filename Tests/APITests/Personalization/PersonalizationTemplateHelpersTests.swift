// Tests/APITests/Personalization/PersonalizationTemplateHelpersTests.swift
//
// Pure-function cases for two personalization helpers in
// `Sources/APIServer/Utilities`: the names that content uses and declares
// (`PersonalizationPlaceholders`), and the template restore on a notebook save
// (`PersonalizedCellRestoration`). Each case answers a mutant that survived the
// database-free suites in the 2026-11-17 steward mutation run. None needs a
// database.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct PersonalizationTemplateHelpersTests {
    private func emptyManifest() throws -> TestProperties {
        try #require(decodeManifest(fromJSON: TestManifests.emptySuite))
    }

    private func notebook(_ cells: String...) -> Data {
        Data(#"{"cells":[\#(cells.joined(separator: ","))],"metadata":{},"nbformat":4,"nbformat_minor":5}"#.utf8)
    }

    // MARK: - PersonalizationPlaceholders

    /// A `$name` argument of a pattern-family case is a use of `name`, as is
    /// the case's expected-value reference.
    @Test func aFamilyArgumentReferenceIsAUse() throws {
        var manifest = try emptyManifest()
        let testCase = PatternCase(
            key: "01", label: "one", args: [.int(1), .int(2)], expected: .int(3),
            argVarRefs: ["dose", nil], expectedVarRef: "total")
        manifest.testItems = [
            .family(
                PatternFamily(
                    id: "fam", name: "Family", kind: .boundaryEquality, functionName: "f",
                    paramNames: ["a", "b"], cases: [testCase]))
        ]
        let used = PersonalizationPlaceholders.used(notebookData: nil, manifest: manifest)
        #expect(used == ["dose", "total"])
    }

    /// A section expression declares its name, as a section variable does.
    @Test func aSectionExpressionIsDeclared() throws {
        let manifest = try #require(
            decodeManifest(
                fromJSON: """
                    {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,\
                    "sections":[{"id":"s1","name":"Part 1",\
                    "variables":[{"name":"rate","value":2}],\
                    "expressions":[{"name":"cutoff","expression":"seed % 7"}]}]}
                    """))
        #expect(PersonalizationPlaceholders.declared(in: manifest) == ["rate", "cutoff"])
    }

    // MARK: - PersonalizedCellRestoration

    /// A tagged cell whose id the stored notebook does not have cannot get its
    /// template back, so the save is refused with the names at risk.
    @Test func aTaggedCellWithAnUnknownIDIsUnmatched() {
        let canonical = notebook(#"{"cell_type":"code","id":"c1","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = notebook(
            #"{"cell_type":"code","id":"c9","metadata":{"chickadee_personalized":"n"},"source":"n = 3"}"#)
        let outcome = PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical)
        #expect(outcome == .unmatched(placeholders: ["n"]))
    }

    /// Without cell ids, the stored cell at the same index is the template
    /// when it is a code cell that carries the placeholder.
    @Test func anIDLessCellTakesTheCodeCellAtTheSameIndex() throws {
        let canonical = notebook(#"{"cell_type":"code","metadata":{},"source":"n = {{n}}"}"#)
        let incoming = notebook(
            #"{"cell_type":"code","metadata":{"chickadee_personalized":"n"},"source":"n = 3"}"#)
        let outcome = PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical)
        guard case .restored(let bytes) = outcome else {
            throw IssueRecorded("The stored code cell carries {{n}}, so the cell restores.")
        }
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(text.contains("n = {{n}}"))
        #expect(!text.contains("chickadee_personalized"))
    }

    /// Without cell ids, a markdown cell at the same index is never the
    /// template, even when its text carries the placeholder.
    @Test func anIDLessCellDoesNotTakeAMarkdownCell() {
        let canonical = notebook(#"{"cell_type":"markdown","metadata":{},"source":"About {{n}}."}"#)
        let incoming = notebook(
            #"{"cell_type":"code","metadata":{"chickadee_personalized":"n"},"source":"n = 3"}"#)
        let outcome = PersonalizedCellRestoration.restoreTemplates(in: incoming, canonical: canonical)
        #expect(outcome == .unmatched(placeholders: ["n"]))
    }
}
