// Tests/CoreTests/FeedbackHandleTests.swift
//
// `FeedbackHandle` is the pseudonym an AI agent sees in place of a student
// (docs/ai-assisted-feedback.md). These tests pin its shape and that the
// shape check refuses anything else.

import Testing

@testable import Core

@Suite struct FeedbackHandleTests {
    @Test func aRandomHandleIsWellFormed() {
        for _ in 0..<200 {
            let handle = FeedbackHandle.random()
            #expect(handle.count == 8)
            #expect(FeedbackHandle.isWellFormed(handle), "\(handle)")
        }
    }

    @Test func handlesDiffer() {
        let handles = Set((0..<200).map { _ in FeedbackHandle.random() })
        #expect(handles.count > 195)
    }

    @Test(arguments: ["", "R-", "R-ABC", "R-ABCDEFG", "X-ABCDEF", "R-ABCDE0", "R-abcdef", "alice"])
    func malformedValuesAreRefused(value: String) {
        #expect(!FeedbackHandle.isWellFormed(value))
    }
}
