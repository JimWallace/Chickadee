// Tests/CoreTests/JSON/JSONValueCppObjectRenderabilityTests.swift
//
// `JSONValue.cppRenderabilityIssue` for objects. `JSONValueCppLiteralTests`
// covers scalars and arrays. The coverage report showed that no test gave it
// an object that holds a null, which has no C++ value, so the save must be
// refused with a reason.

import Testing

@testable import Core

@Suite struct JSONValueCppObjectRenderabilityTests {

    @Test func anObjectHoldingNullIsRefused() throws {
        let value = JSONValue.object(["a": .int(1), "b": .null])

        let issue = try #require(value.cppRenderabilityIssue)
        #expect(issue.contains("object containing null"))
    }

    @Test func anObjectWhoseValuesMixKindsIsRefused() throws {
        let value = JSONValue.object(["a": .int(1), "b": .string("x")])

        let issue = try #require(value.cppRenderabilityIssue)
        #expect(issue.contains("mix kinds"))
    }

    @Test func anEmptyOrSingleKindObjectIsAccepted() {
        #expect(JSONValue.object([:]).cppRenderabilityIssue == nil)
        #expect(JSONValue.object(["a": .int(1), "b": .int(2)]).cppRenderabilityIssue == nil)
    }
}
