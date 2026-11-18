// Tests/CoreTests/FooterJSONParserSeparatorTests.swift
//
// `parseJSON`, the stdlib-only parser that reads a script's result footer
// (RunnerCore/JSONLite.swift). The coverage report showed that no test gave it
// an object or an array whose members have no comma between them. A footer
// like that is not JSON, so the parser must return nil, and the output
// contract then treats the line as plain text.

import Testing

@testable import RunnerCore

@Suite struct FooterJSONParserSeparatorTests {

    @Test(arguments: [
        #"{"score": 0.5 "shortResult": "half"}"#,
        #"{"score": 0.5; "shortResult": "half"}"#,
        "[1 2]",
        "[1; 2]",
        #"[1, 2"#,
        #"{"score": 0.5"#,
    ])
    func aMissingOrWrongSeparatorIsNotJSON(text: String) {
        #expect(parseJSON(text) == nil)
    }

    @Test func membersWithCommasParse() {
        #expect(
            parseJSON(#"{"score": 0.5, "tags": [1, "a", true, null]}"#)
                == .object([
                    "score": .number(0.5),
                    "tags": .array([.number(1), .string("a"), .bool(true), .null]),
                ]))
    }

    @Test func emptyContainersParse() {
        #expect(parseJSON("{}") == .object([:]))
        #expect(parseJSON("[ ]") == .array([]))
    }
}
