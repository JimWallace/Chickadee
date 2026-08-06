import Testing

@testable import Core

// `luaLiteral` is the Lua counterpart of `pythonLiteral` / `rLiteral` — the
// renderer that embeds an authored value into generated test source and into
// `_ck_inputs.lua`.
//
// It exists ahead of `AssignmentLanguage.lua` on purpose: it is the one piece
// of the second half (docs/adding-a-xeus-kernel.md) that can be written and
// PROVEN in isolation, and the generated-literal escaping is where a wrong
// answer turns into a wrong mark rather than a crash. Every expectation below
// was checked against a real `lua 5.4`.
@Suite struct JSONValueLuaLiteralTests {

    @Test func scalars() {
        // Standing alone, a JSON null is Lua's `nil`. Inside a table it is not
        // — see `nullInsideATableBecomesTheSentinel`.
        #expect(JSONValue.null.luaLiteral == "nil")
        #expect(JSONValue.bool(true).luaLiteral == "true")
        #expect(JSONValue.bool(false).luaLiteral == "false")
        #expect(JSONValue.int(5).luaLiteral == "5")
        #expect(JSONValue.int(-3).luaLiteral == "-3")
        // Lua 5.4 distinguishes integers from floats, so a JSON double must
        // keep its point or it comes back as an integer.
        #expect(JSONValue.double(2.0).luaLiteral == "2.0")
        #expect(JSONValue.double(2.5).luaLiteral == "2.5")
    }

    @Test func nonFiniteDoublesUseArithmeticSpellings() {
        // Lua has no `inf` / `nan` literals; these are how the language spells
        // them, parenthesised so they survive being embedded in an expression.
        #expect(JSONValue.double(.nan).luaLiteral == "(0/0)")
        #expect(JSONValue.double(.infinity).luaLiteral == "(1/0)")
        #expect(JSONValue.double(-.infinity).luaLiteral == "(-1/0)")
    }

    @Test func strings() {
        #expect(JSONValue.string("ACGT").luaLiteral == "\"ACGT\"")
        #expect(JSONValue.string("a\"b").luaLiteral == "\"a\\\"b\"")
        #expect(JSONValue.string("a\\b").luaLiteral == "\"a\\\\b\"")
        // A literal newline inside a quoted Lua string is a syntax error, so
        // this escape is load-bearing rather than cosmetic.
        #expect(JSONValue.string("a\nb").luaLiteral == "\"a\\nb\"")
        #expect(JSONValue.string("a\tb").luaLiteral == "\"a\\tb\"")
    }

    @Test func otherControlCharactersUseDecimalEscapes() {
        // `\xNN` is Lua 5.2+; the decimal form works everywhere and is exactly
        // three digits so a following digit cannot extend the escape.
        #expect(JSONValue.string("a\u{01}b").luaLiteral == "\"a\\001b\"")
        #expect(JSONValue.string("a\u{7F}b").luaLiteral == "\"a\\127b\"")
    }

    @Test func arraysAreTableConstructors() {
        #expect(JSONValue.array([.int(1), .int(2)]).luaLiteral == "{1, 2}")
        #expect(JSONValue.array([.string("a"), .string("b")]).luaLiteral == "{\"a\", \"b\"}")
        #expect(JSONValue.array([]).luaLiteral == "{}")
        // Lua has one composite type, so a mixed array needs no second form —
        // the distinction R draws between `c()` and `list()` has no analogue.
        #expect(JSONValue.array([.int(1), .string("a")]).luaLiteral == "{1, \"a\"}")
    }

    @Test func nullInsideATableBecomesTheSentinel() {
        // The trap this renderer exists to avoid: a `nil` in a table
        // constructor is NOT STORED, so `{60, nil, 20}` has an unspecified
        // length and silently breaks the positional alignment an authored case
        // depends on. R hits the same problem with NULL and answers NA; Lua has
        // no missing-value scalar, so a sentinel table occupies the slot.
        #expect(
            JSONValue.array([.int(60), .null, .int(20)]).luaLiteral
                == "{60, chickadee.NULL, 20}")
        #expect(
            JSONValue.object(["a": .null]).luaLiteral
                == "{[\"a\"] = chickadee.NULL}")
    }

    @Test func objectsUseBracketedQuotedKeysInSortedOrder() {
        // Sorted for deterministic output (the rendered source feeds spec_hash).
        #expect(
            JSONValue.object(["b": .int(2), "a": .int(1)]).luaLiteral
                == "{[\"a\"] = 1, [\"b\"] = 2}")
        // Bracketed-and-quoted rather than the bare `end = 1` form, because a
        // JSON key may be a Lua reserved word or contain characters no
        // identifier can. Both of these are syntax errors unbracketed.
        #expect(JSONValue.object(["end": .int(1)]).luaLiteral == "{[\"end\"] = 1}")
        #expect(JSONValue.object(["a b": .int(1)]).luaLiteral == "{[\"a b\"] = 1}")
        #expect(JSONValue.object([:]).luaLiteral == "{}")
    }

    @Test func nestingComposes() {
        #expect(
            JSONValue.object(["xs": .array([.int(1), .int(2)])]).luaLiteral
                == "{[\"xs\"] = {1, 2}}")
        #expect(
            JSONValue.array([.object(["a": .int(1)])]).luaLiteral
                == "{{[\"a\"] = 1}}")
    }
}
