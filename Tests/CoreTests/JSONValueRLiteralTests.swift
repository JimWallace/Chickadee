import Testing

@testable import Core

@Suite struct JSONValueRLiteralTests {
    @Test func scalars() {
        #expect(JSONValue.null.rLiteral == "NULL")
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
        // An array containing null falls through to list() (c() would drop it).
        #expect(JSONValue.array([.int(1), .null]).rLiteral == "list(1, NULL)")
    }

    @Test func objectsAreSortedNamedLists() {
        let obj = JSONValue.object(["b": .int(1), "a": .int(2)])
        #expect(obj.rLiteral == "list(a = 2, b = 1)")
    }

    @Test func nonSyntacticObjectKeysAreQuoted() {
        #expect(JSONValue.object(["a b": .int(1)]).rLiteral == "list(\"a b\" = 1)")
    }
}
