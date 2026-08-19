// Tests/CoreTests/JSONValueJavaLiteralTests.swift
//
// The Java literal renderer and its companion type classifier, neither of
// which had a test anywhere in the tree before this file: `javaLiteral` and
// `javaDeclaredType` appeared under `Sources/` and nowhere under `Tests/`.
// The 2026-08-19 mutation sweep reported all sixteen of their mutants as
// survivors, which for code no test references is the only answer it could
// have given.
//
// `JavaLiteralTypingTests` below is named by `JSONValueJavaLiteral.swift`'s own
// doc comment as the thing that "pins that every `javaLiteral` output
// classifies to a type that actually holds it". It did not exist. The round
// trip it describes is worth pinning for the reason the doc gives — declaring
// every field `Object` does not compile at the call site, so the classifier's
// answers decide whether a generated test builds at all — so the suite is
// written here under the name already documented rather than under a new one.
//
// Each test names the mutation it was written to kill.

import Foundation
import Testing

@testable import Core

@Suite struct JSONValueJavaLiteralTests {

    /// Kills the `SwapTernary` at the `.bool` case.
    @Test func booleansRenderAsJavaKeywords() {
        #expect(JSONValue.bool(true).javaLiteral == "true")
        #expect(JSONValue.bool(false).javaLiteral == "false")
    }

    @Test func nullRendersAsJavasNull() {
        #expect(JSONValue.null.javaLiteral == "null")
    }

    /// Kills the `ChangeLogicalConnector`, both `RelationalOperatorReplacement`
    /// candidates and the `SwapTernary` on the int-width guard — the one place
    /// in this renderer where a wrong answer fails to BUILD rather than
    /// producing a wrong value. Java widens `int` to `long` but never narrows,
    /// so an `L` suffix on a value that fits in `int` makes "possible lossy
    /// conversion" of every call into a student's `f(int x)`.
    ///
    /// The boundaries are tested exactly, not approximately: a mutant that
    /// shifts `>` to `>=` is invisible to any test that only checks a value
    /// well inside the range.
    @Test func intsTakeTheLongSuffixOnlyPastInt32() {
        #expect(JSONValue.int(0).javaLiteral == "0")
        #expect(JSONValue.int(1).javaLiteral == "1")
        #expect(JSONValue.int(-1).javaLiteral == "-1")
        // Exactly at the boundaries: still `int`.
        #expect(JSONValue.int(2_147_483_647).javaLiteral == "2147483647")
        #expect(JSONValue.int(-2_147_483_648).javaLiteral == "-2147483648")
        // One step past, in both directions: now `long`.
        #expect(JSONValue.int(2_147_483_648).javaLiteral == "2147483648L")
        #expect(JSONValue.int(-2_147_483_649).javaLiteral == "-2147483649L")
    }

    /// Kills the `SwapTernary` and the FIRST `ChangeLogicalConnector` on the
    /// double guard: an integral double must keep its point or the literal
    /// changes type, and it must not gain a second one.
    @Test func integralDoublesKeepTheirPoint() {
        #expect(JSONValue.double(2).javaLiteral == "2.0")
        #expect(JSONValue.double(-4).javaLiteral == "-4.0")
        #expect(JSONValue.double(1.5).javaLiteral == "1.5")
    }

    /// Kills the SECOND `ChangeLogicalConnector` on that guard, which the
    /// integral cases cannot reach because they satisfy the first term and
    /// short-circuit.
    @Test func exponentialDoublesAreNotGivenASpuriousPoint() {
        #expect(JSONValue.double(1e-5).javaLiteral == "1e-05")
        #expect(JSONValue.double(1e20).javaLiteral == "1e+20")
    }

    @Test func nonFiniteDoublesUseTheBoxedConstants() {
        #expect(JSONValue.double(.nan).javaLiteral == "Double.NaN")
        #expect(JSONValue.double(.infinity).javaLiteral == "Double.POSITIVE_INFINITY")
        #expect(JSONValue.double(-.infinity).javaLiteral == "Double.NEGATIVE_INFINITY")
    }

    /// `Arrays.asList`, always — never `List.of`, which throws on a null
    /// element and would turn an authored case carrying a JSON null into a
    /// runtime error. The null case is the one worth pinning, since one form
    /// for every array is what stops it reaching a branch nobody tested.
    @Test func arraysAlwaysUseArraysAsList() {
        #expect(JSONValue.array([]).javaLiteral == "java.util.Arrays.asList()")
        #expect(JSONValue.array([.int(1), .int(2)]).javaLiteral == "java.util.Arrays.asList(1, 2)")
        #expect(
            JSONValue.array([.int(1), .null, .string("x")]).javaLiteral
                == #"java.util.Arrays.asList(1, null, "x")"#)
    }

    /// Kills the `RelationalOperatorReplacement` on the key sort. Map equality
    /// is order-independent, so the ordering is not what makes a test pass —
    /// it is what makes the generated source stable across runs, and the
    /// `spec_hash` header depends on that.
    @Test func objectKeysAreSortedAscending() {
        #expect(
            JSONValue.object([:]).javaLiteral
                == "new java.util.LinkedHashMap<String, Object>()")
        #expect(
            JSONValue.object(["b": .int(2), "a": .int(1), "c": .int(3)]).javaLiteral
                == #"new java.util.LinkedHashMap<String, Object>() {{ put("a", 1); put("b", 2); put("c", 3); }}"#
        )
    }

    @Test func stringsTakeCStyleEscapes() {
        #expect(JSONValue.string("ok").javaLiteral == #""ok""#)
        #expect(JSONValue.string("a\"b").javaLiteral == #""a\"b""#)
        #expect(JSONValue.string(#"a\b"#).javaLiteral == #""a\\b""#)
        #expect(JSONValue.string("a\nb\tc\rd").javaLiteral == #""a\nb\tc\rd""#)
        // Non-ASCII passes through as UTF-8 source bytes.
        #expect(JSONValue.string("é").javaLiteral == #""é""#)
    }

    /// Kills the `ChangeLogicalConnector` and both
    /// `RelationalOperatorReplacement` candidates in the string encoder's
    /// control-character guard.
    ///
    /// The escapes are three-digit OCTAL, and the renderer's doc explains the
    /// rule that forces it: Java processes a backslash-u escape in the lexer,
    /// before it knows what a string literal is, so the one for a newline
    /// becomes a real line break mid-string and the file fails to compile.
    /// This test is therefore also the guard against anyone "simplifying" the
    /// encoder to match its five siblings.
    @Test func controlCharactersUseThreeDigitOctalNeverUnicodeEscapes() {
        #expect(JSONValue.string("a\u{01}b").javaLiteral == #""a\001b""#)
        #expect(JSONValue.string("a\u{00}b").javaLiteral == #""a\000b""#)
        #expect(JSONValue.string("a\u{1F}b").javaLiteral == #""a\037b""#)
        // 0x7F is above the 0x20 floor, so it is the second term's own case.
        #expect(JSONValue.string("a\u{7F}b").javaLiteral == #""a\177b""#)
        // 0x20 itself is printable and must survive as a space.
        #expect(JSONValue.string("a b").javaLiteral == #""a b""#)
        // Whatever else changes, a backslash-u escape must never be emitted.
        for scalar in UInt32(0)...UInt32(0x7F) {
            guard let u = Unicode.Scalar(scalar) else { continue }
            #expect(!JSONValue.string(String(Character(u))).javaLiteral.contains(#"\u"#))
        }
    }
}

/// The round trip `JSONValueJavaLiteral.swift` already documents: every
/// `javaLiteral` output must classify to a Java type that actually holds it.
///
/// This matters at the point `_ck_inputs.java` is written, where the value is
/// gone and only its rendered source remains — so the classifier reads text,
/// and a wrong answer is a compile error in a generated file rather than a
/// wrong mark. The sweep found four of its five branches unpinned.
@Suite struct JavaLiteralTypingTests {

    /// Kills the `RelationalOperatorReplacement` at the null branch and both
    /// the `ChangeLogicalConnector` and the two `RelationalOperatorReplacement`
    /// candidates at the boolean branch.
    ///
    /// Note the asymmetry: negating the null test does NOT change the answer
    /// for `null` itself, which reaches the same `Object` through the trailing
    /// fallback. It changes the answer for everything else, so `true` and
    /// `false` are what detect it — and both are needed, since each mutant of
    /// the boolean branch spares one of them.
    @Test func scalarLiteralsClassifyToPrimitives() {
        #expect(javaDeclaredType(forLiteral: "null") == "Object")
        #expect(javaDeclaredType(forLiteral: "true") == "boolean")
        #expect(javaDeclaredType(forLiteral: "false") == "boolean")
        #expect(javaDeclaredType(forLiteral: #""hi""#) == "String")
        #expect(javaDeclaredType(forLiteral: "Double.NaN") == "double")
    }

    /// Kills the `SwapTernary` on the sign strip. Swapped, a negative literal
    /// keeps its sign and fails the `isNumber` test while a positive one loses
    /// its first digit — so both signs are needed, and both fall through to
    /// `Object`, which compiles but will not pass to a student's `f(int x)`.
    @Test func signedNumbersClassifyByWidthNotBySign() {
        #expect(javaDeclaredType(forLiteral: "5") == "int")
        #expect(javaDeclaredType(forLiteral: "-5") == "int")
        #expect(javaDeclaredType(forLiteral: "2147483648L") == "long")
        #expect(javaDeclaredType(forLiteral: "-2147483649L") == "long")
        #expect(javaDeclaredType(forLiteral: "2.0") == "double")
        #expect(javaDeclaredType(forLiteral: "-2.0") == "double")
        #expect(javaDeclaredType(forLiteral: "1e-05") == "double")
    }

    @Test func containersClassifyToTheirInterfaces() {
        #expect(
            javaDeclaredType(forLiteral: "java.util.Arrays.asList(1, 2)")
                == "java.util.List<Object>")
        #expect(
            javaDeclaredType(forLiteral: "new java.util.LinkedHashMap<String, Object>()")
                == "java.util.Map<String, Object>")
    }

    /// An unrecognised shape falls back to `Object` — the safe direction, per
    /// the renderer's doc: it compiles for any use that does not need a
    /// primitive.
    @Test func unrecognisedShapesFallBackToObject() {
        #expect(javaDeclaredType(forLiteral: "someIdentifier") == "Object")
        #expect(javaDeclaredType(forLiteral: "") == "Object")
    }

    /// The round trip itself, over one value of every `JSONValue` case. This
    /// is the assertion the renderer's doc claims exists; the per-branch tests
    /// above are what make each mutation individually visible.
    @Test(arguments: [
        (JSONValue.null, "Object"),
        (JSONValue.bool(true), "boolean"),
        (JSONValue.int(5), "int"),
        (JSONValue.int(-5), "int"),
        (JSONValue.int(2_147_483_648), "long"),
        (JSONValue.double(2), "double"),
        (JSONValue.double(1e-5), "double"),
        (JSONValue.double(.nan), "double"),
        (JSONValue.string("hi"), "String"),
        (JSONValue.array([.int(1)]), "java.util.List<Object>"),
        (JSONValue.object(["a": .int(1)]), "java.util.Map<String, Object>"),
    ])
    func everyRenderedLiteralClassifiesToATypeThatHoldsIt(
        value: JSONValue, expected: String
    ) {
        #expect(javaDeclaredType(forLiteral: value.javaLiteral) == expected)
    }
}
