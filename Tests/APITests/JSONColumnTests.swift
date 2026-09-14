// Tests/APITests/JSONColumnTests.swift

import Testing

@testable import APIServer

@Suite struct JSONColumnTests {
    @Test func encodesWithSortedKeysAndRoundTrips() {
        let encoded = JSONColumn.encode(["b": 2, "a": 1])
        #expect(encoded == #"{"a":1,"b":2}"#)
        #expect(JSONColumn.decode(encoded, defaultValue: [String: Int]()) == ["a": 1, "b": 2])
    }

    @Test func undecodableTextYieldsTheDefault() {
        #expect(JSONColumn.decode("not json", defaultValue: ["fallback"]) == ["fallback"])
        #expect(JSONColumn.decode("", defaultValue: 7) == 7)
    }
}
