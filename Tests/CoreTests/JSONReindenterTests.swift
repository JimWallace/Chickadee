// Tests/CoreTests/JSONReindenterTests.swift
//
// `JSONReindenter` (docs/fhir-datasets-plan.md §5): pretty-printing adds
// whitespace only. Key order, number spelling and string contents are copied
// from the source, so the output is the same on every platform.

import Testing

@testable import Core

@Suite struct JSONReindenterTests {

    @Test func aResourceKeepsItsKeyOrderAndNumbers() {
        let line =
            #"{"resourceType":"Observation","id":"o1","valueQuantity":{"value":38.40,"unit":"Cel"},"#
            + #""note":[],"meta":{},"flags":[true,null,1e3]}"#
        let expected = """
            {
              "resourceType": "Observation",
              "id": "o1",
              "valueQuantity": {
                "value": 38.40,
                "unit": "Cel"
              },
              "note": [],
              "meta": {},
              "flags": [
                true,
                null,
                1e3
              ]
            }
            """
        #expect(JSONReindenter.reindent(line) == expected)
    }

    /// Brackets, commas, colons and escaped quotes inside a string are text.
    @Test func stringsAreCopiedExactly() {
        let line = #"{"text":"a, {b}: [c] \"d\" \\","é":"\u00e9"}"#
        let expected = """
            {
              "text": "a, {b}: [c] \\"d\\" \\\\",
              "é": "\\u00e9"
            }
            """
        #expect(JSONReindenter.reindent(line) == expected)
    }

    @Test func existingWhitespaceIsReplaced() {
        #expect(JSONReindenter.reindent("{ \"a\" :\n 1 }", indent: 4) == "{\n    \"a\": 1\n}")
    }

    @Test(arguments: ["", "{", #"{"a":}"#, "not json"])
    func anInvalidDocumentIsNil(text: String) {
        #expect(JSONReindenter.reindent(text) == nil)
    }
}
