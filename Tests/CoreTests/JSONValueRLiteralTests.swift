import Testing

@testable import Core

@Suite struct JSONValueRLiteralTests {
    @Test func scalars() {
        // A JSON null is a missing value: NA, not NULL. NULL is zero-length and
        // would vanish inside c(), silently shortening the vector.
        #expect(JSONValue.null.rLiteral == "NA")
        #expect(JSONValue.bool(true).rLiteral == "TRUE")
        #expect(JSONValue.bool(false).rLiteral == "FALSE")
        #expect(JSONValue.int(5).rLiteral == "5")
        #expect(JSONValue.int(-3).rLiteral == "-3")
        #expect(JSONValue.double(2.0).rLiteral == "2.0")
        #expect(JSONValue.double(2.5).rLiteral == "2.5")
    }

    @Test func strings() {
        #expect(JSONValue.string("ACGT").rLiteral == "\"ACGT\"")
        // A double quote and a newline must be escaped for an R string literal.
        #expect(JSONValue.string("a\"b").rLiteral == "\"a\\\"b\"")
        #expect(JSONValue.string("a\nb").rLiteral == "\"a\\nb\"")
        #expect(JSONValue.string("a\\b").rLiteral == "\"a\\\\b\"")
    }

    @Test func homogeneousScalarArraysUseC() {
        #expect(JSONValue.array([.string("a"), .string("b")]).rLiteral == "c(\"a\", \"b\")")
        #expect(JSONValue.array([.int(1), .int(2)]).rLiteral == "c(1, 2)")
        #expect(JSONValue.array([.bool(true), .bool(false)]).rLiteral == "c(TRUE, FALSE)")
        // int + double are both numeric → still a homogeneous c() vector.
        #expect(JSONValue.array([.int(1), .double(2.5)]).rLiteral == "c(1, 2.5)")
    }

    @Test func mixedNestedOrEmptyArraysUseList() {
        #expect(JSONValue.array([.int(1), .string("a")]).rLiteral == "list(1, \"a\")")
        #expect(JSONValue.array([]).rLiteral == "list()")
        // Arrays of arrays (A2's read-sets shape) nest c() vectors inside a list.
        #expect(
            JSONValue.array([
                .array([.string("a"), .string("b")]),
                .array([.string("c")]),
            ]).rLiteral == "list(c(\"a\", \"b\"), c(\"c\"))")
        // Nested arrays still list(), even when they carry nulls.
        #expect(
            JSONValue.array([
                .array([.int(1), .null]),
                .array([.int(2)]),
            ]).rLiteral == "list(c(1, NA), c(2))")
    }

    /// A null is a wildcard: it renders as NA, which R admits into an atomic
    /// vector of any type, so interleaving one must not demote the array to a
    /// list. This is what makes an NA-bearing pattern-family case authorable —
    /// previously `[60, null, 20]` became `list(60, NULL, 20)` and the student's
    /// function was handed a list, failing with "'list' object cannot be
    /// coerced to type 'double'".
    @Test func nullsInterleaveIntoHomogeneousVectors() {
        #expect(JSONValue.array([.int(60), .null, .int(20)]).rLiteral == "c(60, NA, 20)")
        #expect(
            JSONValue.array([.string("G2"), .null, .string("G4")]).rLiteral
                == "c(\"G2\", NA, \"G4\")")
        #expect(
            JSONValue.array([.bool(false), .null, .bool(true)]).rLiteral
                == "c(FALSE, NA, TRUE)")
        // Leading / trailing nulls, and more than one of them.
        #expect(
            JSONValue.array([.null, .int(95), .null, .int(5)]).rLiteral == "c(NA, 95, NA, 5)")
        // A lone null, and an all-null array: c(NA) / c(NA, NA) are logical NA
        // vectors, matching what R's own JSON readers produce.
        #expect(JSONValue.array([.null]).rLiteral == "c(NA)")
        #expect(JSONValue.array([.null, .null]).rLiteral == "c(NA, NA)")
        // A null does not rescue a genuinely mixed array.
        #expect(
            JSONValue.array([.int(1), .null, .string("a")]).rLiteral == "list(1, NA, \"a\")")
    }

    @Test func objectsAreSortedNamedLists() {
        let obj = JSONValue.object(["b": .int(1), "a": .int(2)])
        #expect(obj.rLiteral == "list(a = 2, b = 1)")
    }

    @Test func nonSyntacticObjectKeysAreQuoted() {
        #expect(JSONValue.object(["a b": .int(1)]).rLiteral == "list(\"a b\" = 1)")
    }
}
