// Tests/APITests/Languages/OctaveScriptHelpersTests.swift
//
// The Octave identifier and type-predicate helpers that the Octave renderers
// call. The validator refuses an unusable name upstream, so the generated-
// script suites only reach the identity path of `octaveIdentifier` and the
// common type names. These tests reach the sanitiser and every branch of the
// type-name table, because a name that slips past validation, or a family
// converted from Python or R, still has to produce valid Octave.

import Core
import Testing

@testable import APIServer

@Suite struct OctaveScriptHelpersTests {

    // MARK: - isValidOctaveIdentifier

    @Test func aLeadingUnderscoreIsValidButALeadingDigitIsNot() {
        #expect(isValidOctaveIdentifier("_total"))
        #expect(isValidOctaveIdentifier("x2"))
        #expect(!isValidOctaveIdentifier("2x"))
        #expect(!isValidOctaveIdentifier(""))
    }

    @Test func aReservedWordOrANonASCIILetterIsNotAnIdentifier() {
        #expect(!isValidOctaveIdentifier("endfunction"))
        #expect(!isValidOctaveIdentifier("unwind_protect"))
        #expect(!isValidOctaveIdentifier("café"))
        #expect(!isValidOctaveIdentifier("a-b"))
    }

    // MARK: - octaveIdentifier

    @Test func aValidNameIsReturnedUnchanged() {
        #expect(octaveIdentifier("mean_bp") == "mean_bp")
    }

    @Test(arguments: [
        ("a-b c", "a_b_c"),
        ("2fast", "_2fast"),
        ("", "_"),
        ("é", "_"),
        ("for", "for_"),
        ("end-if", "end_if"),
    ])
    func anUnusableNameIsRewrittenToAValidOne(input: String, expected: String) {
        let rewritten = octaveIdentifier(input)
        #expect(rewritten == expected)
        #expect(isValidOctaveIdentifier(rewritten))
    }

    // MARK: - octaveComment

    @Test func aCommentNeverCarriesALineBreak() {
        let flattened = octaveComment("first\nsecond\rthird")
        #expect(!flattened.contains("\n"))
        #expect(!flattened.contains("\r"))
        #expect(flattened.contains("first"))
        #expect(flattened.contains("third"))
    }

    // MARK: - octaveTypeCheckExpression

    @Test(arguments: [
        ("int", "isnumeric(v)"),
        ("Float", "isnumeric(v)"),
        ("str", "ischar(v)"),
        ("character", "ischar(v)"),
        ("bool", "islogical(v)"),
        ("LOGICAL", "islogical(v)"),
        ("list", "iscell(v)"),
        ("cell", "iscell(v)"),
        ("dict", "isa(v, \"containers.Map\")"),
        ("containers.Map", "isa(v, \"containers.Map\")"),
        ("struct", "isstruct(v)"),
        ("callable", "is_function_handle(v)"),
        ("function_handle", "is_function_handle(v)"),
        ("matrix", "(isnumeric(v) && ismatrix(v))"),
        ("vector", "(isnumeric(v) && isvector(v))"),
        ("None", "isempty(v)"),
        ("empty", "isempty(v)"),
        ("any", "true"),
        ("object", "true"),
    ])
    func aKnownTypeNameMapsToItsPredicate(typeName: String, expected: String) {
        #expect(octaveTypeCheckExpression(typeName: typeName, valueExpr: "v") == expected)
    }

    /// An unknown name becomes a class check that keeps the author's
    /// spelling (not lowercased), because Octave class names are
    /// case-sensitive.
    @Test func anUnknownTypeNameFallsBackToAnIsaCheckWithTheNameAsWritten() {
        #expect(octaveTypeCheckExpression(typeName: "MyClass", valueExpr: "r") == "isa(r, \"MyClass\")")
    }

    @Test func thePredicateTestsTheExpressionItIsGiven() {
        #expect(octaveTypeCheckExpression(typeName: "struct", valueExpr: "result") == "isstruct(result)")
    }
}
