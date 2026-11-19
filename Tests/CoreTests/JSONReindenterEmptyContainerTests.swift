// Tests/CoreTests/JSONReindenterEmptyContainerTests.swift
//
// An empty object or array stays `{}` or `[]` on one line, even when the
// source has whitespace between the brackets. `skipWhitespace` is what looks
// past that whitespace, and `JSONReindenterTests` only uses empty containers
// written without any, so the 2026-11-13 sweep (#3015) saw its loop
// condition `index < scalars.count` flipped to `>` survive. With the flip the
// loop never runs, and `{ }` lays out as an open brace, a blank indented line
// and a close brace. FHIR resources may carry such whitespace.

import Core
import Testing

@Suite struct JSONReindenterEmptyContainerTests {

    @Test(
        arguments: [
            ("{ }", "{}"),
            ("[\t]", "[]"),
            ("[\r\n  ]", "[]"),
            (#"{"note": [ ], "meta": {  }}"#, "{\n  \"note\": [],\n  \"meta\": {}\n}"),
        ])
    func whitespaceInsideAnEmptyContainerIsDropped(source: String, expected: String) {
        #expect(JSONReindenter.reindent(source) == expected)
    }
}
