// Tests/APITests/PatternFamilySectionsTests.swift
//
// Split from PatternFamilyTests.swift.  See PatternFamilyTestCase.swift
// for shared family fixtures (bmiFamily, approxFamily,
// notebookVariablesFamily, helloPrintsFamily) and the Fixture plumbing
// helpers (makeFixture, writeEmptyZip, etc.).

import Core
import Crypto
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct PatternFamilySectionsTests {

    // MARK: - Sections (v0.4.96)

    @Test func apply_familySectionStampsEveryGeneratedEntry() async throws {
        try await withPatternFamilyFixture { fixture in

            let sections = [TestSuiteSection(id: "sec-a", name: "Question 1")]
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [pfBMIFamily()],
                authoredItems: [.family(id: "bmi_category", sectionID: "sec-a")],
                sections: sections,
                on: fixture.app.db
            )

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.sections.map(\.id) == ["sec-a"])
            #expect(props.testSuites.isEmpty == false)
            for entry in props.testSuites {
                #expect(
                    entry.sectionID == "sec-a",
                    "Every generated entry must inherit the family's authored sectionID; got \(entry.sectionID ?? "nil") for \(entry.script)"
                )
            }

        }
    }

    @Test func apply_staleSectionIDRewrittenToNil() async throws {
        try await withPatternFamilyFixture { fixture in

            let sections = [TestSuiteSection(id: "sec-keep", name: "Kept")]
            let authored: [AuthoredSuiteItem] = [
                .script(
                    AuthoredRawScript(
                        script: "publictest_a.py", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [],
                        sectionID: "sec-gone"  // not in sections list → must be nil'd
                    ))
            ]
            // Need the script to exist in the zip first.
            try applyScriptChangesToZip(
                zipPath: fixture.setup.zipPath,
                writes: ["publictest_a.py": "#!/usr/bin/env python3\nexit(0)\n"],
                deletions: []
            )

            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [],
                authoredItems: authored,
                sections: sections,
                on: fixture.app.db
            )

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.sections.map(\.id) == ["sec-keep"])
            #expect(props.testSuites.count == 1)
            #expect(
                props.testSuites.first?.sectionID == nil,
                "A sectionID pointing at a section not in the list must be rewritten to nil.")

        }
    }

    /// v0.4.134 regression guard.  The Create-page publish flow
    /// (`saveNewAssignment`) used to call `makeWorkerManifestJSON` with
    /// only `patternFamilies` forwarded — `sections` and `notebookChecks`
    /// defaulted to `[]`, silently dropping any sections / checks
    /// authored on the create page.  Likewise per-entry `sectionID` was
    /// lost through the `ReindexedSuiteConfigRow` JSON round-trip.  The
    /// fix passes all three fields through and reconstructs sectionID
    /// from the draft's manifest in `authoredSuiteItemsFromDraftManifest`.
    /// This test exercises the full simulated-publish round-trip so a
    /// future regression on any of the three fields fails loudly.
    @Test func apply_createPublishPreservesSectionsAndChecks() async throws {
        try await withPatternFamilyFixture { fixture in

            try applyScriptChangesToZip(
                zipPath: fixture.setup.zipPath,
                writes: [
                    "publictest_a.py": "#!/usr/bin/env python3\nexit(0)\n",
                    "publictest_b.py": "#!/usr/bin/env python3\nexit(0)\n",
                ],
                deletions: []
            )

            // Draft state: one section, one raw script in that section, one
            // ungrouped raw script, one notebook check, one pattern family.
            let sectionID = "sec-warmup"
            let sections = [TestSuiteSection(id: sectionID, name: "Warmup")]
            let check = NotebookCheck(
                id: "df_shape", kind: .dataFrameShape,
                tier: .pub, points: 1,
                sectionID: sectionID,
                variable: "df", expectedRows: 5, expectedCols: 2
            )
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [pfBMIFamily()],
                nextChecks: [check],
                authoredItems: [
                    .script(
                        AuthoredRawScript(
                            script: "publictest_a.py", tier: .pub, points: 1,
                            displayName: nil, dependsOn: [], sectionID: sectionID
                        )),
                    .family(id: "bmi_category", sectionID: sectionID),
                    .check(id: "df_shape", sectionID: sectionID),
                    .script(
                        AuthoredRawScript(
                            script: "publictest_b.py", tier: .pub, points: 1,
                            displayName: nil, dependsOn: [], sectionID: nil
                        )),
                ],
                sections: sections,
                on: fixture.app.db
            )
            let draftProps = try pfDecodeManifest(fixture.setup.manifest)
            #expect(draftProps.sections.count == 1, "Pre-condition: draft must have a section")
            #expect(draftProps.notebookChecks.count == 1, "Pre-condition: draft must have a notebook check")
            #expect(draftProps.patternFamilies.count == 1, "Pre-condition: draft must have a pattern family")

            // Simulate `saveNewAssignment`'s manifest rebuild step: it
            // iterates the manifest's testSuites to reconstruct
            // `ReindexedSuiteConfigRow` (sectionID stripped), then builds
            // `ConfiguredSuiteEntry` from that.  We reproduce that lossy
            // round-trip here so the test exercises the same path the
            // server takes on publish.
            let lossyRawEntries: [ConfiguredSuiteEntry] = [
                ConfiguredSuiteEntry(
                    script: "publictest_a.py", tier: "public",
                    order: 1, dependsOn: [], points: 1, displayName: nil),
                ConfiguredSuiteEntry(
                    script: "publictest_b.py", tier: "public",
                    order: 2, dependsOn: [], points: 1, displayName: nil),
            ]

            // Step 1 of the publish path: rebuild the manifest with all
            // three custom fields forwarded (this is the v0.4.134 fix).
            fixture.setup.manifest = try makeWorkerManifestJSON(
                testSuites: lossyRawEntries,
                includeMakefile: false,
                patternFamilies: draftProps.patternFamilies,
                notebookChecks: draftProps.notebookChecks,
                sections: draftProps.sections
            )
            try await fixture.setup.save(on: fixture.app.db)

            // Step 2 of the publish path: re-apply with authoredItems
            // reconstructed from the draft manifest.  This is the only
            // path that re-stamps each entry's sectionID after the
            // ReindexedSuiteConfigRow round-trip stripped it.
            let authored = authoredSuiteItemsFromDraftManifest(
                draftProps: draftProps,
                newRawEntries: lossyRawEntries
            )
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: draftProps.patternFamilies,
                nextChecks: draftProps.notebookChecks,
                authoredItems: authored,
                sections: draftProps.sections,
                on: fixture.app.db
            )

            let props = try pfDecodeManifest(fixture.setup.manifest)

            // Sections survive.
            #expect(props.sections.map(\.id) == [sectionID], "Sections must survive the publish-from-create rebuild")

            // Pattern family + notebook check survive.
            #expect(props.patternFamilies.map(\.id) == ["bmi_category"])
            #expect(props.notebookChecks.map(\.id) == ["df_shape"])

            // Per-entry sectionID survives:
            //   - publictest_a.py was authored in the section
            //   - bmi_category's three generated entries were too
            //   - df_shape's generated entry was too
            //   - publictest_b.py was authored ungrouped → sectionID nil
            let bySection = Dictionary(grouping: props.testSuites, by: { $0.sectionID })
            #expect(
                bySection[sectionID]?.count ?? 0 == 5,
                "Five entries must keep sectionID=\(sectionID): publictest_a.py + 3 generated bmi_category + 1 generated df_shape; got: \(props.testSuites.map { "\($0.script)→\($0.sectionID ?? "nil")" })"
            )
            #expect(
                bySection[nil]?.map(\.script) == ["publictest_b.py"],
                "publictest_b.py must remain ungrouped after publish")

        }
    }

    @Test func apply_nonContiguousSectionsRejected() async throws {
        try await withPatternFamilyFixture { fixture in

            try applyScriptChangesToZip(
                zipPath: fixture.setup.zipPath,
                writes: [
                    "publictest_a.py": "#!/usr/bin/env python3\nexit(0)\n",
                    "publictest_b.py": "#!/usr/bin/env python3\nexit(0)\n",
                    "publictest_c.py": "#!/usr/bin/env python3\nexit(0)\n",
                ],
                deletions: []
            )

            let sections = [
                TestSuiteSection(id: "sec-a", name: "A"),
                TestSuiteSection(id: "sec-b", name: "B"),
            ]
            // Authored: [A, B, A] — A-items split across the B block.
            let authored: [AuthoredSuiteItem] = [
                .script(
                    AuthoredRawScript(
                        script: "publictest_a.py", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: "sec-a")),
                .script(
                    AuthoredRawScript(
                        script: "publictest_b.py", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: "sec-b")),
                .script(
                    AuthoredRawScript(
                        script: "publictest_c.py", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: "sec-a")),
            ]

            do {
                _ = try await applyPatternFamilies(
                    to: fixture.setup,
                    nextFamilies: [],
                    authoredItems: authored,
                    sections: sections,
                    on: fixture.app.db
                )
                Issue.record("Expected non-contiguous section arrangement to throw.")
            } catch let abort as AbortError {
                #expect(abort.status == .unprocessableEntity)
                #expect(
                    abort.reason.contains("contiguous"),
                    "Error should mention contiguity; got: \(abort.reason)")
            }

        }
    }

    @Test func apply_deletingSectionReHomesItemsToUngrouped() async throws {
        try await withPatternFamilyFixture { fixture in

            try applyScriptChangesToZip(
                zipPath: fixture.setup.zipPath,
                writes: ["publictest_a.py": "#!/usr/bin/env python3\nexit(0)\n"],
                deletions: []
            )

            // Save with one section, one item in it.
            let initialSections = [TestSuiteSection(id: "sec-temp", name: "Temp")]
            let authored: [AuthoredSuiteItem] = [
                .script(
                    AuthoredRawScript(
                        script: "publictest_a.py", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: "sec-temp"))
            ]
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [],
                authoredItems: authored,
                sections: initialSections,
                on: fixture.app.db
            )

            // Delete the section — caller re-sends authored items with the
            // same sectionID, and an empty sections list.  Server must
            // re-home those items to Ungrouped.
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [],
                authoredItems: authored,
                sections: [],
                on: fixture.app.db
            )

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.sections.isEmpty)
            #expect(props.testSuites.count == 1)
            #expect(
                props.testSuites.first?.sectionID == nil,
                "Items whose section was deleted must fall back to nil sectionID.")

        }
    }

}
