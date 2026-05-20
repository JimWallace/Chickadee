// Tests/APITests/PythonTypeCheckExpressionTests.swift
//
// Byte-stability guard for `pythonTypeCheckExpression` — the type-name →
// runtime-check builder shared by NotebookCheckRenderer (`.variableExists`)
// and PatternFamilyRenderer (`.returnTypeCheck`).  These two used to carry
// independent byte-for-byte copies (issue #497); the helper now lives once in
// PythonScriptHelpers.swift.  Its output bytes are content-addressed via
// spec_hash and drive TestSetupCache invalidation, so any drift here changes
// every generated script's hash — these golden assertions exist to make such
// a change a deliberate, visible test edit.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct PythonTypeCheckExpressionTests {

    // Every supported type name paired with the exact expression the helper
    // must emit for value variable `result`.  Adding a case is fine; changing
    // an existing string is a deliberate byte break (and re-hashes every
    // generated script that uses it).
    private static let goldenForResult: [(typeName: String, expr: String)] = [
        ("int", "isinstance(result, int) and not isinstance(result, bool)"),
        ("float", "isinstance(result, float)"),
        ("bool", "isinstance(result, bool)"),
        ("str", "isinstance(result, str)"),
        ("list", "isinstance(result, list)"),
        ("tuple", "isinstance(result, tuple)"),
        ("dict", "isinstance(result, dict)"),
        ("set", "isinstance(result, set)"),
        ("NoneType", "result is None"),
        ("DataFrame", #"any(getattr(b, "__name__", "") == "DataFrame" for b in type(result).__mro__)"#),
        ("Series", #"any(getattr(b, "__name__", "") == "Series" for b in type(result).__mro__)"#),
        ("ndarray", #"any(getattr(b, "__name__", "") == "ndarray" for b in type(result).__mro__)"#),
        // Unknown name falls through to the MRO-name walk.
        ("MyCustomClass", #"any(getattr(b, "__name__", "") == "MyCustomClass" for b in type(result).__mro__)"#),
    ]

    @Test func builtinsAndLibraryTypes_areByteStable() {
        for (typeName, expr) in Self.goldenForResult {
            #expect(
                pythonTypeCheckExpression(typeName: typeName, valueExpr: "result") == expr,
                "byte drift for type `\(typeName)` — this changes generated spec_hash values")
        }
    }

    @Test func parameterizedByValueExpr_onlyVariableNameDiffers() {
        // The helper is the same logic for both call sites; the only thing
        // that varies is the Python variable holding the value to test.
        for (typeName, _) in Self.goldenForResult {
            let withResult = pythonTypeCheckExpression(typeName: typeName, valueExpr: "result")
            let withActual = pythonTypeCheckExpression(typeName: typeName, valueExpr: "actual")
            #expect(
                withResult.replacingOccurrences(of: "result", with: "actual") == withActual,
                "expressions for `\(typeName)` should differ only by the value variable name")
        }
    }

    // MARK: - Both renderers wire through the shared helper

    @Test func variableExistsRenderer_embedsHelperOutput_forActual() {
        for typeName in ["int", "DataFrame", "MyCustomClass"] {
            let check = NotebookCheck(
                id: "v", kind: .variableExists, variable: "x", expectedType: typeName)
            let source = renderNotebookCheck(check).script.source
            let expected = pythonTypeCheckExpression(typeName: typeName, valueExpr: "actual")
            #expect(
                source.contains(expected),
                ".variableExists must emit the shared helper's `actual` expression for `\(typeName)`")
        }
    }

    @Test func returnTypeCheckRenderer_embedsHelperOutput_forResult() throws {
        for typeName in ["int", "DataFrame", "MyCustomClass"] {
            let family = PatternFamily(
                id: "rt", name: "Return type", kind: .returnTypeCheck,
                functionName: "make_thing", paramNames: ["n"],
                cases: [
                    PatternCase(
                        key: "01", label: "make_thing returns \(typeName)",
                        args: [.int(1)], expected: .string(typeName))
                ])
            let source = try #require(renderPatternFamily(family).first).source
            let expected = pythonTypeCheckExpression(typeName: typeName, valueExpr: "result")
            #expect(
                source.contains(expected),
                ".returnTypeCheck must emit the shared helper's `result` expression for `\(typeName)`")
        }
    }
}
