// A Lua pattern family's function target must follow Lua's own grammar.
//
// `isValidFunctionTarget` used Python's rule for Lua, which accepts Lua's
// reserved words. The Lua renderer looks the target up as a string key
// (`rawget(student, function_name)`), so a family targeting `end` rendered a
// test, but no student can define a function named `end`, so the test could
// never pass and the author got no error at save time (#2259, item 8).

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct LuaFunctionTargetTests {

    private func family(function: String) -> PatternFamily {
        PatternFamily(
            id: "bmi",
            name: "BMI category boundaries",
            kind: .boundaryEquality,
            functionName: function,
            paramNames: ["bmi"],
            cases: [
                PatternCase(
                    key: "01", label: "Below the lower boundary",
                    args: [.double(17.2)], expected: .string("underweight"))
            ]
        )
    }

    private func validate(_ function: String, _ language: AssignmentLanguage) throws {
        try validatePatternFamilies([family(function: function)], testSuites: [], language: language)
    }

    /// Lua reserved words are refused as a Lua target at save time.
    @Test(arguments: ["end", "local", "then", "function", "nil"])
    func luaRefusesAReservedWord(word: String) {
        #expect(!isValidFunctionTarget(word, language: .lua))
        #expect(throws: (any Error).self) { try validate(word, .lua) }
    }

    /// The same words are ordinary Python names, so the refusal is specific to
    /// Lua and not a general tightening.
    @Test func theSameWordsAreValidPythonTargets() throws {
        for word in ["end", "local", "then"] {
            try validate(word, .python)
        }
    }

    /// The function-target rule and the bare-name rule agree for Lua, so a name
    /// that the Lua validator refuses as a variable is also refused as a target.
    @Test(arguments: ["bmi_category", "_private", "f2", "end", "goto", "2f", "bmi.category", "bmi-category"])
    func targetRuleMatchesTheLuaIdentifierRule(name: String) {
        #expect(isValidFunctionTarget(name, language: .lua) == isValidLuaIdentifier(name))
    }
}
