// Tests/CoreTests/LuaLiteralContractTests.swift
//
// The Swift half of the Lua literal contract. See RLiteralContractTests for the
// arrangement: neither implementation owns the expectations, both read
// Tests/Fixtures/lua-literal-contract.json, so an unmirrored change to either
// fails on both sides.
//
// The browser half is Tests/BrowserRunnerJSTests/lua-literal-contract.test.mjs.

import Foundation
import Testing

@testable import Core

@Suite struct LuaLiteralContractTests {

    private struct Contract: Decodable {
        struct Case: Decodable {
            let name: String
            let json: JSONValue?
            let lua: String
        }
        let cases: [Case]
    }

    /// The fixture, found relative to this source file so the test does not
    /// depend on the working directory a runner happens to use.
    private static func loadContract() throws -> Contract {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/lua-literal-contract.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode(Contract.self, from: data)
    }

    @Test func everyContractCaseRendersIdenticallyOnTheServer() throws {
        let contract = try Self.loadContract()
        #expect(contract.cases.count > 20, "the contract should cover a real spread of shapes")
        for testCase in contract.cases {
            let value = testCase.json ?? .null
            #expect(
                value.luaLiteral == testCase.lua,
                """
                \(testCase.name): server luaLiteral disagrees with the contract.
                  contract: \(testCase.lua)
                  rendered: \(value.luaLiteral)
                """)
        }
    }

    /// The arms JSON cannot express, so the shared fixture cannot pin them.
    /// `0/0` and `1/0` are how Lua spells the non-finite literals it cannot
    /// otherwise parse.
    @Test func theNonJSONNumericArmsRenderAsLuaSpellsThem() {
        #expect(JSONValue.double(.nan).luaLiteral == "(0/0)")
        #expect(JSONValue.double(.infinity).luaLiteral == "(1/0)")
        #expect(JSONValue.double(-.infinity).luaLiteral == "(-1/0)")
    }

    /// Lua 5.4 distinguishes integers from floats, so a whole-number double
    /// keeps its decimal point. The browser cannot reproduce this — JS has one
    /// number type — which is why the fixture holds no case for it.
    @Test func aWholeNumberDoubleKeepsItsDecimalPoint() {
        #expect(JSONValue.double(2).luaLiteral == "2.0")
        #expect(JSONValue.int(2).luaLiteral == "2")
    }
}
