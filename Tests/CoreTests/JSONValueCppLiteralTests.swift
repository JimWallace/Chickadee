// Tests/CoreTests/JSONValueCppLiteralTests.swift
//
// The C++ literal renderer: the first statically-typed target, whose rule is
// the opposite of Octave's — nothing may guess a type. Scalars render with
// one obvious type, single-kind containers render explicitly typed, and
// everything whose type would be a guess is refused at save time
// (`cppRenderabilityIssue`) with a loud-compile-error backstop in the
// rendered text.

import Foundation
import Testing

@testable import Core

@Suite struct JSONValueCppLiteralTests {

    @Test func scalarsRenderWithTheirNaturalTypes() {
        #expect(JSONValue.int(42).cppLiteral == "42")
        #expect(JSONValue.bool(true).cppLiteral == "true")
        #expect(JSONValue.bool(false).cppLiteral == "false")
        #expect(JSONValue.double(1.5).cppLiteral == "1.5")
        #expect(JSONValue.string("ok").cppLiteral == #"std::string("ok")"#)
    }

    /// A double that happens to be integral must stay a double — `4.0`, not
    /// `4`, or the rendered expression changes type.
    @Test func integralDoublesKeepTheirPoint() {
        #expect(JSONValue.double(4).cppLiteral == "4.0")
    }

    /// Beyond int32, the literal takes the LL suffix so the rendered
    /// expression's type never depends on the target's `int`.
    @Test func wideIntsTakeTheSuffix() {
        #expect(JSONValue.int(2_147_483_647).cppLiteral == "2147483647")
        #expect(JSONValue.int(2_147_483_648).cppLiteral == "2147483648LL")
        #expect(JSONValue.int(-2_147_483_649).cppLiteral == "-2147483649LL")
    }

    @Test func nonFiniteDoublesUseTheStdSpellings() {
        #expect(JSONValue.double(.nan).cppLiteral == #"std::nan("")"#)
        #expect(
            JSONValue.double(.infinity).cppLiteral
                == "std::numeric_limits<double>::infinity()")
    }

    /// Control characters take three-digit octal (never `\x`, which consumes
    /// every following hex digit); quotes and backslashes escape C-style.
    @Test func stringsEscapeSafely() {
        #expect(
            JSONValue.string("a\"b\\c\nd").cppLiteral
                == #"std::string("a\"b\\c\nd")"#)
        #expect(JSONValue.string("bell\u{07}x").cppLiteral == #"std::string("bell\007x")"#)
    }

    @Test func singleKindArraysRenderExplicitlyTyped() {
        #expect(
            JSONValue.array([.int(1), .int(2)]).cppLiteral
                == "std::vector<long long>{1, 2}")
        #expect(
            JSONValue.array([.string("a"), .string("b")]).cppLiteral
                == #"std::vector<std::string>{std::string("a"), std::string("b")}"#)
        #expect(
            JSONValue.array([.bool(true), .bool(false)]).cppLiteral
                == "std::vector<bool>{true, false}")
    }

    /// Mixed int/double is still one numeric kind: everything renders as
    /// double, so `{1, 2.5}` never trips list-init narrowing.
    @Test func mixedNumericsPromoteToDouble() {
        #expect(
            JSONValue.array([.int(1), .double(2.5)]).cppLiteral
                == "std::vector<double>{1.0, 2.5}")
    }

    @Test func emptyArraysRenderAsEmptyDoubleVectors() {
        #expect(JSONValue.array([]).cppLiteral == "std::vector<double>{}")
    }

    @Test func objectsRenderAsMapsWithSortedKeys() {
        #expect(
            JSONValue.object(["b": .int(2), "a": .int(1)]).cppLiteral
                == #"std::map<std::string, long long>{{"a", 1}, {"b", 2}}"#)
    }

    /// The refusals: null, mixed kinds, nesting. Each names its reason at
    /// save time, and the rendered backstop is an undefined identifier so a
    /// leak is a compile error, never a plausible wrong value.
    @Test func unrenderableValuesAreRefusedAndLoud() {
        #expect(JSONValue.null.cppRenderabilityIssue != nil)
        #expect(JSONValue.null.cppLiteral.contains("CK_UNRENDERABLE"))

        let mixed = JSONValue.array([.int(1), .string("two")])
        #expect(mixed.cppRenderabilityIssue != nil)
        #expect(mixed.cppLiteral.contains("CK_UNRENDERABLE"))

        let nested = JSONValue.array([.array([.int(1)])])
        #expect(nested.cppRenderabilityIssue != nil)

        let nullInArray = JSONValue.array([.int(1), .null])
        #expect(nullInArray.cppRenderabilityIssue != nil)

        let mixedObject = JSONValue.object(["a": .int(1), "b": .string("x")])
        #expect(mixedObject.cppRenderabilityIssue != nil)
    }

    /// Bools never fold into the numeric kinds: `[true, 1.5]` would be a
    /// silent re-reading of the author's value.
    @Test func boolsDoNotMixWithNumerics() {
        #expect(JSONValue.array([.bool(true), .int(1)]).cppRenderabilityIssue != nil)
    }

    @Test func renderableScalarsAndContainersReportNoIssue() {
        #expect(JSONValue.int(1).cppRenderabilityIssue == nil)
        #expect(JSONValue.array([.int(1), .double(2)]).cppRenderabilityIssue == nil)
        #expect(JSONValue.object(["k": .string("v")]).cppRenderabilityIssue == nil)
    }

    /// Kills the `SwapTernary` on the object arm's empty/unrenderable split
    /// (2026-08-25 sweep, run 32886018037). Swapped, an empty object renders
    /// the loud backstop while a mixed-value object renders a plausible empty
    /// `std::map` — the silent wrong value the backstop exists to prevent.
    /// The tests above pin the mixed object's *renderability issue* but never
    /// the literal text either branch actually emits, which is why the swap
    /// survived.
    @Test func emptyObjectsRenderAsEmptyMapsAndUnrenderableOnesStayLoud() {
        #expect(JSONValue.object([:]).cppLiteral == "std::map<std::string, double>{}")
        let mixedObject = JSONValue.object(["a": .int(1), "b": .string("x")])
        #expect(mixedObject.cppLiteral == "CK_UNRENDERABLE_OBJECT_HAS_NO_SINGLE_CPP_VALUE_TYPE")
    }
}
