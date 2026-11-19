// Tests/APITests/Assignments/SuiteRowHelperOrderingTests.swift
//
// `authoredSuiteItemsFromDraftManifest` decides the suite order that a
// publish from the create page keeps: each family and each notebook check at
// the position of its first generated entry, hand-written scripts in draft
// order, and new uploads at the end. `familySuiteRowsForSetup` builds the
// family rows of the editor's suite table. Both are pure over their inputs, so
// no database is needed: the setup is an in-memory model.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SuiteRowHelperOrderingTests {

    private static func raw(
        _ script: String, tier: String = "public", points: Int = 1, sectionID: String? = nil
    ) -> ConfiguredSuiteEntry {
        ConfiguredSuiteEntry(
            script: script, tier: tier, order: 0, dependsOn: [], points: points,
            displayName: nil, sectionID: sectionID)
    }

    private static func rawScript(_ item: AuthoredSuiteItem) -> AuthoredRawScript? {
        if case .script(let raw) = item { return raw }
        return nil
    }

    private static func scriptName(_ item: AuthoredSuiteItem) -> String? {
        rawScript(item)?.script
    }

    // MARK: - authoredSuiteItemsFromDraftManifest

    @Test func withoutADraftEveryNewEntryIsAScriptInOrder() throws {
        let items = authoredSuiteItemsFromDraftManifest(
            draftProps: nil,
            newRawEntries: [Self.raw("b.sh", tier: "secret", points: 3), Self.raw("a.sh", tier: "bogus")])

        #expect(items.compactMap(Self.scriptName) == ["b.sh", "a.sh"])
        let first = try #require(items.first.flatMap(Self.rawScript))
        #expect(first.tier == .secret)
        #expect(first.points == 3)
        let second = try #require(items.last.flatMap(Self.rawScript))
        #expect(second.tier == .pub, "an unknown tier string falls back to public")
    }

    @Test func familiesAndChecksKeepTheirDraftPositionOnce() {
        let draft = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "one.sh"),
                TestSuiteEntry(tier: .pub, script: "test_fam_01.py", generatedBy: "fam", sectionID: "s1"),
                TestSuiteEntry(tier: .pub, script: "test_fam_02.py", generatedBy: "fam", sectionID: "s1"),
                TestSuiteEntry(tier: .pub, script: "publiccheck_c1.py", generatedByCheck: "c1", sectionID: "s2"),
                TestSuiteEntry(tier: .pub, script: "two.sh"),
            ],
            language: .python)
        let items = authoredSuiteItemsFromDraftManifest(
            draftProps: draft, newRawEntries: [Self.raw("two.sh"), Self.raw("one.sh")])

        #expect(
            items == [
                .script(
                    AuthoredRawScript(
                        script: "one.sh", tier: .pub, points: 1, displayName: nil, dependsOn: [], sectionID: nil)),
                .family(id: "fam", sectionID: "s1"),
                .check(id: "c1", sectionID: "s2"),
                .script(
                    AuthoredRawScript(
                        script: "two.sh", tier: .pub, points: 1, displayName: nil, dependsOn: [], sectionID: nil)),
            ])
    }

    @Test func aDraftScriptMissingFromTheNewZipIsDropped() {
        let draft = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "gone.sh"), TestSuiteEntry(tier: .pub, script: "kept.sh")],
            language: .python)
        let items = authoredSuiteItemsFromDraftManifest(draftProps: draft, newRawEntries: [Self.raw("kept.sh")])

        #expect(items.compactMap(Self.scriptName) == ["kept.sh"])
    }

    @Test func newUploadsAbsentFromTheDraftGoAtTheEnd() throws {
        let draft = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "test_fam_01.py", generatedBy: "fam"),
                TestSuiteEntry(tier: .pub, script: "old.sh"),
            ],
            language: .python)
        let items = authoredSuiteItemsFromDraftManifest(
            draftProps: draft,
            newRawEntries: [Self.raw("fresh.sh", sectionID: "s9"), Self.raw("old.sh")])

        #expect(items.count == 3)
        #expect(items.first == .family(id: "fam", sectionID: nil))
        #expect(items.compactMap(Self.scriptName) == ["old.sh", "fresh.sh"])
        let fresh = try #require(items.last.flatMap(Self.rawScript), "expected the new upload last")
        #expect(fresh.sectionID == "s9")
    }

    @Test func theDraftSectionWinsOverTheRebuiltEntrySection() {
        let draft = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.sh", sectionID: "draft"),
                TestSuiteEntry(tier: .pub, script: "b.sh"),
            ],
            language: .python)
        let items = authoredSuiteItemsFromDraftManifest(
            draftProps: draft,
            newRawEntries: [Self.raw("a.sh", sectionID: "rebuilt"), Self.raw("b.sh", sectionID: "rebuilt")])

        let sections = items.map { Self.rawScript($0)?.sectionID }
        // The draft's section for a.sh; b.sh has none in the draft, so the
        // rebuilt entry's section is kept.
        #expect(sections == ["draft", "rebuilt"])
    }

    // MARK: - familySuiteRowsForSetup

    @Test func familyRowsCountOnlyEnabledCasesAndResolvePoints() throws {
        let family = PatternFamily(
            id: "fam", name: "Doubling", kind: .boundaryEquality, functionName: "double",
            paramNames: ["x"], defaults: PatternDefaults(tier: .release, points: 2),
            cases: [
                PatternCase(key: "01", label: "", args: [.int(1)], expected: .int(2)),
                PatternCase(key: "02", label: "", args: [.int(2)], expected: .int(4), points: 5),
                PatternCase(key: "03", label: "", args: [.int(3)], expected: .int(6), enabled: false),
            ])
        let props = TestProperties(language: .python, patternFamilies: [family])
        let manifest = try #require(String(data: try JSONEncoder().encode(props), encoding: .utf8))
        let setup = APITestSetup(id: "s", manifest: manifest, zipPath: "/nonexistent.zip", courseID: UUID())

        let rows = familySuiteRowsForSetup(setup)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == "fam")
        #expect(row.name == "Doubling")
        #expect(row.functionName == "double")
        #expect(row.tier == "release")
        #expect(row.caseCount == 2)
        #expect(row.totalPoints == 7)
        #expect(row.caseCountText == "2 cases")
    }

    @Test func anUndecodableManifestGivesNoFamilyRows() {
        let setup = APITestSetup(id: "s", manifest: "not json", zipPath: "/nonexistent.zip", courseID: UUID())
        #expect(familySuiteRowsForSetup(setup).isEmpty)
    }

    @Test func familyRowEncodesItsCaseCountText() throws {
        let one = FamilySuiteRow(
            id: "f", name: "F", functionName: "f", tier: "public", caseCount: 1, totalPoints: 1)
        #expect(one.caseCountText == "1 case")

        let data = try JSONEncoder().encode(one)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["caseCountText"] as? String == "1 case")
        #expect(object["totalPoints"] as? Int == 1)
        #expect(object["functionName"] as? String == "f")
        #expect(
            Set(object.keys) == ["id", "name", "functionName", "tier", "caseCount", "totalPoints", "caseCountText"])
    }
}
