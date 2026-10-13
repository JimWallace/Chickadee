// Tests/CoreTests/CompositeContributionTests.swift
//
// Pins how a footer's optional `composite` object becomes a
// `CompositeContribution` (docs/class-composite.md, slice 1). The shared
// output contract pins a few rows on both runners; these cases cover each
// shape rule on its own, the size cap, and the JSON keys that the browser and
// the worker post to the server.

import Core
import Foundation
import Testing

@Suite struct CompositeContributionTests {

    private func interpret(footer: String, exitCode: Int32 = 0) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(exitCode: exitCode, stdout: footer, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    /// A footer with one composite object; `fields` replaces the valid
    /// defaults (a 2 × 1 grey image, the bytes 0 and 255).
    private func footer(_ fields: [String: String] = [:]) -> String {
        var values = ["w": "2", "h": "1", "frames": "1", "format": "\"gray8\"", "data": "\"AP8=\""]
        values.merge(fields) { _, new in new }
        let body = values.keys.sorted().map { "\"\($0)\":\(values[$0] ?? "")" }.joined(separator: ",")
        return "{\"score\":1,\"composite\":{\(body)}}"
    }

    @Test func validGreyImageIsCarriedThroughUnchanged() throws {
        let composite = try #require(interpret(footer: footer()).composite)
        #expect(composite == CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: "AP8="))
        #expect(composite.expectedByteCount == 2)
    }

    @Test func validRGBFramesAreCarriedThrough() throws {
        // 1 × 1 pixel, 2 frames, 3 channels: 6 bytes, base64 with no padding.
        let result = interpret(
            footer: footer(["w": "1", "frames": "2", "format": "\"rgb8\"", "data": "\"AAAA////\""]))
        let composite = try #require(result.composite)
        #expect(composite.format == .rgb8)
        #expect(composite.expectedByteCount == 6)
    }

    @Test func compositeDoesNotChangeTheGrade() {
        let with = interpret(footer: footer(), exitCode: 1)
        let without = interpret(footer: "{\"score\":1}", exitCode: 1)
        #expect(with.composite != nil)
        #expect(with.status == without.status)
        #expect(with.score == without.score)
    }

    @Test func footerWithoutCompositeHasNone() {
        #expect(interpret(footer: "{\"score\":1}").composite == nil)
        #expect(interpret(footer: "plain text").composite == nil)
    }

    @Test(arguments: [
        ["w": "0"],
        ["h": "-1"],
        ["w": "1.5"],
        ["frames": "\"1\""],
        ["w": "1e9"],
        ["format": "\"rgba8\""],
        ["format": "1"],
        ["data": "1"],
        ["h": "2"],  // 4 bytes expected, 2 supplied
        ["data": "\"AP8\""],  // length not a multiple of four
        ["data": "\"AP8*\""],  // byte outside the alphabet
        ["data": "\"A=P8\""],  // data after padding
        ["data": "\"A===\""],  // three padding bytes
        ["data": "\"AP-_\""],  // URL-safe alphabet is not standard base64
    ])
    func invalidShapeYieldsNoContribution(fields: [String: String]) {
        #expect(interpret(footer: footer(fields)).composite == nil)
    }

    @Test func compositeThatIsNotAnObjectIsIgnored() {
        #expect(interpret(footer: "{\"composite\":\"AP8=\"}").composite == nil)
        #expect(interpret(footer: "{\"composite\":null}").composite == nil)
    }

    @Test func payloadAtTheCapIsAcceptedAndOverTheCapIsNot() {
        let cap = CompositeContribution.maxPayloadBytes
        let atCap = Data(count: cap).base64EncodedString()
        #expect(
            interpret(footer: footer(["w": "256", "h": "256", "data": "\"\(atCap)\""])).composite != nil)
        // Every dimension is within its own range; only the byte count is over.
        let overCap = Data(count: 256 * 257).base64EncodedString()
        #expect(
            interpret(footer: footer(["w": "256", "h": "257", "data": "\"\(overCap)\""])).composite == nil)
    }

    @Test func dimensionsWhoseProductExceedsTheCapAreRefused() {
        // Each factor is within the cap; the product is not.
        #expect(interpret(footer: footer(["w": "65536", "h": "65536"])).composite == nil)
    }

    /// The server decodes what the worker encodes and what the browser posts,
    /// so the JSON keys are the footer's `w` and `h`, not the Swift names.
    @Test func codableUsesTheFooterKeys() throws {
        let composite = CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: "AP8=")
        let encoded = try JSONEncoder().encode(composite)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["w", "h", "frames", "format", "data"])

        let browserPosted = Data(#"{"w":2,"h":1,"frames":1,"format":"gray8","data":"AP8="}"#.utf8)
        #expect(try JSONDecoder().decode(CompositeContribution.self, from: browserPosted) == composite)
    }

    @Test func outcomeRoundTripsItsComposite() throws {
        let composite = CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: "AP8=")
        let outcome = TestOutcome(
            testName: "tile", testClass: nil, tier: .pub, status: .pass, shortResult: "ok",
            longResult: nil, composite: composite, executionTimeMs: 0, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: true)
        let decoded = try JSONDecoder().decode(TestOutcome.self, from: JSONEncoder().encode(outcome))
        #expect(decoded.composite == composite)
    }

    /// Every outcome stored before class composites existed has no
    /// `composite` key, and must still decode.
    @Test func outcomeWithoutCompositeKeyDecodesToNil() throws {
        let stored = Data(
            #"""
            {"testName":"t","tier":"public","status":"pass","shortResult":"ok",
             "executionTimeMs":0,"attemptNumber":1,"isFirstPassSuccess":true}
            """#.utf8)
        #expect(try JSONDecoder().decode(TestOutcome.self, from: stored).composite == nil)
    }
}
