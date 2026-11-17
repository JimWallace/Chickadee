// Tests/APITests/Assignments/SuiteConfigDecodingErrorTests.swift
//
// A suite config that is present but cannot be read throws
// `SuiteConfigDecodingError` (#2305). The web layer shows its `reason` and
// `status`, so these pin the message and the 400 status.

import Testing
import Vapor

@testable import APIServer

@Suite struct SuiteConfigDecodingErrorTests {

    @Test func statusIsBadRequest() {
        #expect(SuiteConfigDecodingError(underlying: "x").status == .badRequest)
    }

    @Test func reasonNamesTheUnderlyingError() {
        let error = SuiteConfigDecodingError(underlying: "not an array")
        #expect(error.reason == "The suite configuration could not be read: not an array")
    }

    @Test func malformedConfigThrowsAReadableReason() throws {
        let error = try #require(throws: SuiteConfigDecodingError.self) {
            try decodeSuiteConfigRows("{\"index\": 0}")
        }
        #expect(error.reason.hasPrefix("The suite configuration could not be read: "))
        #expect(!error.underlying.isEmpty)
    }

    @Test func blankConfigIsNoConfig() throws {
        #expect(try decodeSuiteConfigRows(nil) == nil)
        #expect(try decodeSuiteConfigRows("  \n ") == nil)
    }
}
