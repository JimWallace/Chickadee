// Tests/CoreTests/RLiteralContractTests.swift
//
// The Swift half of the R literal contract.
//
// `JSONValue.rLiteral` renders a value into R source on the server. `rLiteral`
// in `Public/r-grading-shared.js` does the same in the browser, because in-page
// auto-compute must call an R solution with arguments the instructor typed but
// has not saved — there is no server round-trip in which the server could
// render them.
//
// Two implementations of one rendering is normally the defect this codebase
// keeps removing, and it is allowed here for the same reason
// `personalizationInputsSourceR` is: the browser cannot call Swift. What makes
// it safe is that NEITHER SIDE OWNS THE EXPECTATIONS. Both read
// Tests/Fixtures/r-literal-contract.json, so a change to either that is not
// mirrored fails on both sides — the arrangement
// Tests/Fixtures/output-contract.json already uses to pin RunnerCore's native
// and wasm builds together.
//
// The browser half is Tests/BrowserRunnerJSTests/r-literal-contract.test.mjs.

import Foundation
import Testing

@testable import Core

@Suite struct RLiteralContractTests {

    private struct Contract: Decodable {
        struct Case: Decodable {
            let name: String
            let json: JSONValue?
            let r: String
        }
        let cases: [Case]
    }

    /// The fixture, found relative to this source file so the test does not
    /// depend on the working directory a runner happens to use.
    private static func loadContract() throws -> Contract {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/r-literal-contract.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode(Contract.self, from: data)
    }

    @Test func everyContractCaseRendersIdenticallyOnTheServer() throws {
        let contract = try Self.loadContract()
        #expect(contract.cases.count > 20, "the contract should cover a real spread of shapes")
        for testCase in contract.cases {
            let value = testCase.json ?? .null
            #expect(
                value.rLiteral == testCase.r,
                """
                \(testCase.name): server rLiteral disagrees with the contract.
                  contract: \(testCase.r)
                  rendered: \(value.rLiteral)
                """)
        }
    }

    /// The arms JSON cannot express, so the shared fixture cannot pin them.
    /// Asserted here rather than left uncovered.
    @Test func theNonJSONNumericArmsRenderAsRSpellsThem() {
        #expect(JSONValue.double(.nan).rLiteral == "NaN")
        #expect(JSONValue.double(.infinity).rLiteral == "Inf")
        #expect(JSONValue.double(-.infinity).rLiteral == "-Inf")
    }

    /// A whole-number double keeps its decimal point, so it stays a `double` in
    /// R rather than becoming an integer literal. The browser cannot reproduce
    /// this — JS has one number type — which is exactly why the fixture holds
    /// no case for it and this test does.
    @Test func aWholeNumberDoubleKeepsItsDecimalPoint() {
        #expect(JSONValue.double(2).rLiteral == "2.0")
        #expect(JSONValue.int(2).rLiteral == "2")
    }
}
