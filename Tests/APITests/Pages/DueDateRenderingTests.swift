// Tests/APITests/Pages/DueDateRenderingTests.swift
//
// A follow-up from the review of the UI audit #3007 fixes: `DueDate`
// prints the absolute date once and seeds the relative span empty.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct DueDateRenderingTests {

    @Test func theAbsoluteDateShowsOnceAndTheRelativeSpanIsEmpty() {
        let html = DueDate(iso: "2026-11-20T23:59:00Z", text: "Fri Nov 20, 23:59").render()
        #expect(html.components(separatedBy: "Fri Nov 20, 23:59").count == 2, "the date appears exactly once")
        #expect(html.contains("data-iso=\"2026-11-20T23:59:00Z\"></span>"), "the relative span is seeded empty")
        #expect(!html.contains("·"), "the separator comes from CSS, not the markup")
    }

    @Test func noISOMeansNoRelativeSpan() {
        let html = DueDate(iso: "", text: "Fri Nov 20, 23:59").render()
        #expect(!html.contains("js-relative-time"))
        #expect(html.contains("Due Fri Nov 20, 23:59"))
    }
}
