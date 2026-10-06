// Tests/APITests/MCP/MCPContentByteCapTests.swift
//
// The capped UTF-8 reader shared by get_support_files and
// get_assignment_version (#2334).

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPContentByteCapTests {
    @Test func contentUnderTheCapIsReturnedWhole() throws {
        let read = try #require(MCPContentByteCap.cappedUTF8(Data("héllo".utf8), cap: 100))
        #expect(read.content == "héllo")
        #expect(read.truncated == false)
    }

    @Test func aCutInsideACharacterBacksOffToItsStart() throws {
        // "aé" is 3 bytes; a cap of 2 splits the 2-byte "é".
        let read = try #require(MCPContentByteCap.cappedUTF8(Data("aéz".utf8), cap: 2))
        #expect(read.content == "a")
        #expect(read.truncated)
    }

    @Test func aBinaryFileThatStartsWithASCIIIsNotText() {
        var data = Data("%PDF-1.4\n".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0xC0, 0x80])
        data.append(Data(repeating: 0x41, count: 100))
        #expect(MCPContentByteCap.cappedUTF8(data, cap: 50) == nil)
    }

    @Test func invalidContentUnderTheCapIsNotText() {
        #expect(MCPContentByteCap.cappedUTF8(Data([0xFF, 0x41]), cap: 100) == nil)
    }

    @Test func theCapIsClampedToItsRange() {
        #expect(MCPContentByteCap.resolve(nil) == MCPContentByteCap.defaultBytes)
        #expect(MCPContentByteCap.resolve(0) == 1)
        #expect(MCPContentByteCap.resolve(10_000_000) == MCPContentByteCap.maxBytes)
    }
}
