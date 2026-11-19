// Tests/APITests/Admin/DeployReleaseNotesSectionsTests.swift
//
// The admin Deployment page shows each `### Changed`-style heading above its
// own list. Before, the heading was a bold bullet of one flat list.
// `DeployReleaseNotes.sections(of:)` does the grouping.

import Testing

@testable import APIServer

@Suite struct DeployReleaseNotesSectionsTests {

    private static func entries(_ body: String, contract: Set<Int> = []) -> [DeployReleaseNotes.Entry] {
        DeployReleaseNotes.entries(in: body, contractPullRequests: contract)
    }

    @Test func eachHeadingHoldsTheEntriesUnderIt() {
        let sections = DeployReleaseNotes.sections(
            of: Self.entries("### Changed\n\n- One (#1).\n- Two.\n\n### Fixed\n\n- Three (#3).", contract: [3]))
        #expect(sections.map(\.heading) == ["Changed", "Fixed"])
        #expect(sections.map { $0.items.map(\.text) } == [["One (#1).", "Two."], ["Three (#3)."]])
        #expect(sections.last?.items.first?.isContractChange == true)
        #expect(sections.allSatisfy { $0.items.allSatisfy { !$0.isHeading } })
    }

    @Test func entriesBeforeAnyHeadingFormAnUnheadedSection() {
        let sections = DeployReleaseNotes.sections(of: Self.entries("- Loose.\n\n### Added\n\n- New."))
        #expect(sections.map(\.heading) == [nil, "Added"])
    }

    @Test func aHeadingWithNothingUnderItIsDropped() {
        let sections = DeployReleaseNotes.sections(of: Self.entries("### Changed\n\n### Fixed\n\n- A fix."))
        #expect(sections.map(\.heading) == ["Fixed"])
        #expect(DeployReleaseNotes.sections(of: []).isEmpty)
    }
}
