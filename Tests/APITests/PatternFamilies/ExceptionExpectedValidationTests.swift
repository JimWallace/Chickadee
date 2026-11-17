// Tests/APITests/PatternFamilies/ExceptionExpectedValidationTests.swift
//
// Save-time validation of an `exceptionExpected` family
// (`ExceptionExpectedKind.validateCase`, reached through
// `validatePatternFamilies`). The coverage report showed that no test ever
// validated a family of this kind. A case must name the exception class as a
// non-blank string, and must give one argument per parameter.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct ExceptionExpectedValidationTests {

    private static func family(args: [JSONValue] = [.int(-1)], expected: JSONValue) -> PatternFamily {
        PatternFamily(
            id: "rejects_negative", name: "Rejects a negative mass", kind: .exceptionExpected,
            functionName: "bmi", paramNames: ["mass_kg"],
            cases: [PatternCase(key: "01", label: "negative mass", args: args, expected: expected)])
    }

    @Test func aNamedExceptionClassIsAccepted() throws {
        try validatePatternFamilies(
            [Self.family(expected: .string("ValueError"))], testSuites: [], language: .python)
    }

    @Test(arguments: [JSONValue.string(""), .string("   "), .int(1), .null])
    func anExpectedValueThatIsNotAClassNameIsRefused(expected: JSONValue) {
        #expect(
            throws: AuthoringValidationError.exceptionExpectedNotClassName(familyID: "rejects_negative", caseKey: "01")
        ) {
            try validatePatternFamilies([Self.family(expected: expected)], testSuites: [], language: .python)
        }
    }

    @Test func theWrongArgumentCountIsRefusedFirst() {
        let family = Self.family(args: [.int(-1), .int(2)], expected: .string(""))

        #expect(
            throws: AuthoringValidationError.patternCaseArgCountMismatch(
                familyID: "rejects_negative", kindLabel: "exception_expected", caseKey: "01", argCount: 2,
                parameterCount: 1)
        ) {
            try validatePatternFamilies([family], testSuites: [], language: .python)
        }
    }
}
