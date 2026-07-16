// Tests/APITests/SectionContiguityValidationTests.swift
//
// Unit tests for validateAuthoredSectionContiguity, extracted from the body
// of applyPatternFamilies (#1123): items sharing a sectionID (nil counts as
// the ungrouped "section") must form one contiguous block in the authored
// ordering.

import Core
import Testing
import Vapor

@testable import APIServer

@Suite struct SectionContiguityValidationTests {

    private func script(_ name: String, sectionID: String? = nil) -> AuthoredSuiteItem {
        .script(
            AuthoredRawScript(
                script: name, tier: .pub, points: 1,
                displayName: nil, dependsOn: [], sectionID: sectionID))
    }

    @Test func contiguousBlocksPass() throws {
        try validateAuthoredSectionContiguity([
            script("a.py", sectionID: "s1"),
            script("b.py", sectionID: "s1"),
            .family(id: "f1", sectionID: "s2"),
            script("c.py", sectionID: "s2"),
            script("d.py"),
            .check(id: "c1", sectionID: nil),
        ])
    }

    @Test func emptyAndSingleItemListsPass() throws {
        try validateAuthoredSectionContiguity([])
        try validateAuthoredSectionContiguity([script("a.py", sectionID: "s1")])
    }

    @Test func straddledSectionIsRejected() {
        #expect(throws: Abort.self) {
            try validateAuthoredSectionContiguity([
                script("a.py", sectionID: "s1"),
                script("b.py", sectionID: "s2"),
                script("c.py", sectionID: "s1"),
            ])
        }
    }

    @Test func straddledUngroupedBlockIsRejected() {
        // nil (ungrouped) is a "section" for contiguity purposes too.
        #expect(throws: Abort.self) {
            try validateAuthoredSectionContiguity([
                script("a.py"),
                .family(id: "f1", sectionID: "s1"),
                script("b.py"),
            ])
        }
    }

    @Test func straddleViaFamilyAndCheckItemsIsRejected() {
        #expect(throws: Abort.self) {
            try validateAuthoredSectionContiguity([
                .family(id: "f1", sectionID: "s1"),
                .check(id: "c1", sectionID: "s2"),
                .family(id: "f2", sectionID: "s1"),
            ])
        }
    }
}
