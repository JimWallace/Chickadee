// Tests/CoreTests/OctaveLiteralContractTests.swift
//
// The Swift half of the Octave literal contract.
//
// `JSONValue.octaveLiteral` renders a value into Octave source on the server.
// `octaveLiteral` in `Public/octave-grading-shared.js` does the same in the
// browser, because in-page auto-compute must call an Octave solution with
// arguments the instructor typed but has not saved — there is no server
// round-trip in which the server could render them.
//
// Two implementations of one rendering is normally the defect this codebase
// keeps removing, and it is allowed here for the reason
// `personalizationInputsSourceOctave` is: the browser cannot call Swift. What
// makes it safe is that NEITHER SIDE OWNS THE EXPECTATIONS. Both read
// Tests/Fixtures/octave-literal-contract.json.
//
// The browser half is Tests/BrowserRunnerJSTests/octave-literal-contract.test.mjs.

import Foundation
import Testing

@testable import Core

@Suite struct OctaveLiteralContractTests {

    private struct Contract: Decodable {
        struct Case: Decodable {
            let name: String
            let json: JSONValue?
            let octave: String
        }
        let cases: [Case]
    }

    private static func loadContract() throws -> Contract {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/octave-literal-contract.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode(Contract.self, from: data)
    }

    @Test func everyContractCaseRendersIdenticallyOnTheServer() throws {
        let contract = try Self.loadContract()
        #expect(contract.cases.count > 20, "the contract should cover a real spread of shapes")
        for testCase in contract.cases {
            let value = testCase.json ?? .null
            #expect(
                value.octaveLiteral == testCase.octave,
                """
                \(testCase.name): server octaveLiteral disagrees with the contract.
                  contract: \(testCase.octave)
                  rendered: \(value.octaveLiteral)
                """)
        }
    }

    /// The arms JSON cannot express, so the shared fixture cannot pin them.
    @Test func theNonJSONNumericArmsRenderAsOctaveSpellsThem() {
        #expect(JSONValue.double(.nan).octaveLiteral == "NaN")
        #expect(JSONValue.double(.infinity).octaveLiteral == "Inf")
        #expect(JSONValue.double(-.infinity).octaveLiteral == "-Inf")
    }

    /// A whole-number double keeps its decimal point. The browser cannot
    /// reproduce this — JS has one number type — which is why the fixture holds
    /// no case for it and this test does.
    @Test func aWholeNumberDoubleKeepsItsDecimalPoint() {
        #expect(JSONValue.double(2).octaveLiteral == "2.0")
        #expect(JSONValue.int(2).octaveLiteral == "2")
    }
}
