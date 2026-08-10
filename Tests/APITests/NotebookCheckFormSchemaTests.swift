// Tests/APITests/NotebookCheckFormSchemaTests.swift
//
// PR3 (v0.4.230): the notebook-check editor's per-kind form fields are now
// declared once in Swift (`NotebookCheckFormSchema.swift`) and emitted to the
// browser as a `<script id="check-schema">` seed, replacing the hand-coded
// field cards that used to live in two Leaf templates plus the JS
// reset/populate/build switches.
//
// These tests are the drift guard between the schema and the validators in
// `NotebookCheckKindHandler.swift`:
//   - the schema declares a field list for *every* `NotebookCheckKind`
//     (and the common hint field),
//   - a valid sample for each kind passes its validator, and
//   - clearing any field the schema marks `required` makes that validator
//     throw — so a `required` flag can't silently disagree with what the
//     validator actually enforces.

import Core
import Testing

@testable import APIServer

@Suite struct NotebookCheckFormSchemaTests {

    // MARK: - Coverage

    @Test func schemaDeclaresFieldsForEveryKind() {
        let schema = notebookCheckFormSchema()
        for kind in NotebookCheckKind.allCases {
            let fields = schema.kinds[kind.rawValue]
            #expect(fields != nil, "Schema is missing a field list for kind \(kind.rawValue)")
            #expect(
                !(fields ?? []).isEmpty,
                "Schema field list for \(kind.rawValue) is empty — every kind has at least one input")
        }
        #expect(
            schema.kinds.count == NotebookCheckKind.allCases.count,
            "Schema has a stray kind entry not in NotebookCheckKind")
    }

    @Test func commonFieldsIncludeHint() {
        let schema = notebookCheckFormSchema()
        let names = schema.common.map(\.name)
        #expect(names.contains("hint"), "The pervasive instructor hint must be a common schema field")
    }

    @Test func schemaSerialisesToJSONObject() {
        let json = notebookCheckFormSchemaJSON()
        #expect(json.hasPrefix("{"))
        #expect(json.contains("\"common\""))
        #expect(json.contains("\"kinds\""))
        #expect(json.contains("\"hint\""))
    }

    // MARK: - required ⟷ validator agreement

    @Test func validSamplePassesAndRequiredFieldsAreEnforced() throws {
        let schema = notebookCheckFormSchema()
        for kind in NotebookCheckKind.allCases {
            let handler = notebookCheckKindHandler(for: kind)
            let sample = validSample(for: kind)

            // Positive: a sample built from the kind's required fields validates.
            #expect(
                throws: Never.self,
                "Valid sample for \(kind.rawValue) should pass its validator"
            ) { try handler.validate(sample, language: .python) }

            // Negative: clearing each schema-required field trips the validator.
            let required = (schema.kinds[kind.rawValue] ?? []).filter(\.required).map(\.name)
            for field in required {
                let broken = clearing(field, from: sample)
                #expect(
                    throws: (any Error).self,
                    "Clearing required field '\(field)' for \(kind.rawValue) must fail validation"
                ) { try handler.validate(broken, language: .python) }
            }
        }
    }

    // MARK: - Fixtures

    /// A NotebookCheck whose kind-specific required fields are all populated
    /// with values its validator accepts.
    private func validSample(for kind: NotebookCheckKind) -> NotebookCheck {
        switch kind {
        case .dataFrameShape:
            return NotebookCheck(id: "s", kind: kind, variable: "df", expectedRows: 10, expectedCols: 3)
        case .dataFrameColumns:
            return NotebookCheck(id: "s", kind: kind, variable: "df", expectedColumns: ["a", "b"])
        case .dataFrameEquality:
            return NotebookCheck(id: "s", kind: kind, variable: "df", expectedCSV: "a,b\n1,2\n")
        case .seriesEquality:
            return NotebookCheck(id: "s", kind: kind, variable: "scores", expectedCSV: "v\n1\n2\n")
        case .numericArrayClose:
            return NotebookCheck(id: "s", kind: kind, variable: "arr", expectedArray: [1.0, 2.0])
        case .figureCount:
            return NotebookCheck(id: "s", kind: kind, minFigures: 1)
        case .cellContains:
            return NotebookCheck(id: "s", kind: kind, containsText: ".groupby(")
        case .functionExists:
            return NotebookCheck(id: "s", kind: kind, variable: "classify")
        case .variableExists:
            return NotebookCheck(id: "s", kind: kind, variable: "x")
        case .astStructure:
            return NotebookCheck(id: "s", kind: kind, requiredConstructs: ["for_loop"])
        }
    }

    // MARK: - Field-level language refusals

    /// The form's field annotations come from the SAME predicate the save-time
    /// refusal reads.
    ///
    /// The gap this closes: `cellContains` is a supported kind on Lua, so the
    /// kind-level map the Add Test menu reads said "available" — and then
    /// ticking its regex box produced a check the server refused. Kind-level
    /// availability is not field-level availability, and until now only the
    /// former could be expressed.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyAnnotatedFieldMatchesTheRefusalPredicate(_ language: AssignmentLanguage) {
        let schema = notebookCheckFormSchema(language: language)
        for kind in NotebookCheckKind.allCases {
            for field in schema.kinds[kind.rawValue] ?? [] {
                #expect(
                    field.unsupportedReason
                        == notebookCheckFieldUnsupportedReason(
                            field.name, kind: kind, language: language),
                    """
                    The form schema and the save-time refusal disagree about \
                    \(kind.rawValue).\(field.name) on \(language.displayName).
                    """)
            }
        }
    }

    /// Lua is the one language with a field-level refusal today, and the
    /// annotation lands on exactly the field that is refused.
    @Test func luaRefusesRegexCellMatchingInTheFormAndOnSave() throws {
        let luaFields = try #require(
            notebookCheckFormSchema(language: .lua).kinds[NotebookCheckKind.cellContains.rawValue])
        let regexField = try #require(luaFields.first { $0.name == "regex" })
        let reason = try #require(
            regexField.unsupportedReason, "Lua should refuse regex cell matching")
        #expect(reason.contains("Lua patterns"))
        // Its neighbour in the same kind is untouched: this is a FIELD-level
        // refusal, and a kind-level one would have taken the whole card.
        let textField = try #require(luaFields.first { $0.name == "containsText" })
        #expect(textField.unsupportedReason == nil)
    }

    /// Octave's regexp is PCRE and R's engine takes the same constructs, so a
    /// pattern authored against the Python renderer transfers. Neither is
    /// refused — asserted so a later reader does not "fix" them by symmetry
    /// with Lua.
    @Test(arguments: [AssignmentLanguage.python, .r, .octave])
    func languagesWithCompatibleRegexEnginesAreNotRefused(_ language: AssignmentLanguage) {
        #expect(
            notebookCheckFieldUnsupportedReason("regex", kind: .cellContains, language: language)
                == nil)
    }

    /// The label named Python on every assignment. It now names the language,
    /// and says nothing about one when the assignment declares none.
    @Test func theRegexLabelNamesTheAssignmentLanguage() throws {
        func regexLabel(_ language: AssignmentLanguage?) throws -> String {
            let fields = try #require(
                notebookCheckFormSchema(language: language)
                    .kinds[NotebookCheckKind.cellContains.rawValue])
            return try #require(fields.first { $0.name == "regex" }).label
        }
        #expect(try regexLabel(.r).contains("R regular expression"))
        #expect(try regexLabel(.octave).contains("Octave"))
        #expect(try !regexLabel(.r).contains("Python"))
        // No language declared: no language named.
        #expect(try regexLabel(nil) == "Interpret as a regular expression")
    }

    /// Returns a copy of `s` with the named field cleared to nil.  Covers
    /// every field name any kind marks `required` in the schema.
    private func clearing(_ field: String, from s: NotebookCheck) -> NotebookCheck {
        NotebookCheck(
            id: s.id, name: s.name, kind: s.kind, tier: s.tier, points: s.points,
            dependsOn: s.dependsOn, sectionID: s.sectionID, hint: s.hint,
            variable: field == "variable" ? nil : s.variable,
            expectedRows: field == "expectedRows" ? nil : s.expectedRows,
            expectedCols: field == "expectedCols" ? nil : s.expectedCols,
            expectedColumns: field == "expectedColumns" ? nil : s.expectedColumns,
            columnMatch: s.columnMatch,
            expectedCSV: field == "expectedCSV" ? nil : s.expectedCSV,
            checkDtype: s.checkDtype, checkLike: s.checkLike,
            rtol: s.rtol, atol: s.atol, ignoreIndex: s.ignoreIndex,
            expectedArray: field == "expectedArray" ? nil : s.expectedArray,
            minFigures: field == "minFigures" ? nil : s.minFigures,
            containsText: field == "containsText" ? nil : s.containsText,
            regex: s.regex, mustDifferFrom: s.mustDifferFrom,
            expectedArity: s.expectedArity, expectedType: s.expectedType,
            requiredConstructs: field == "requiredConstructs" ? nil : s.requiredConstructs)
    }
}
