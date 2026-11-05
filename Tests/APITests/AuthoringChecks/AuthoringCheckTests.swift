// Tests/APITests/AuthoringChecks/AuthoringCheckTests.swift
//
// The rule-based authoring checks (#2747). Each check is a pure function of an
// `AuthoringSnapshot`, so these build the snapshot from a manifest literal and
// need no database.

import Core
import Testing

@testable import APIServer

@Suite struct AuthoringCheckTests {
    private func snapshot(_ manifestJSON: String) throws -> AuthoringSnapshot {
        AuthoringSnapshot(manifest: try #require(decodeManifest(fromJSON: manifestJSON)))
    }

    private func suite(_ entries: String, extra: String = "") -> String {
        #"{"schemaVersion":1,"testSuites":["# + entries + #"],"timeLimitSeconds":10"# + extra + "}"
    }

    // MARK: - manifest.incoherent

    @Test func coherenceCheckReportsEachViolationAsAnError() throws {
        let manifest = suite(
            #"{"tier":"public","script":"a.py"}"#,
            extra: #","gradingMode":"browser","submissionMode":"uploadOnly""#)
        let findings = ManifestCoherenceCheck().findings(in: try snapshot(manifest))
        #expect(findings.count == 1)
        #expect(findings.first?.checkID == "manifest.incoherent")
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.location == .assignment)
        #expect(findings.first?.message == uploadModeGradingConflictMessage)
    }

    @Test func coherenceCheckIsQuietOnACoherentManifest() throws {
        #expect(ManifestCoherenceCheck().findings(in: try snapshot(suite(""))).isEmpty)
    }

    // MARK: - tiers.noPublicTest

    @Test func noPublicTestFiresWhenEveryTestIsHidden() throws {
        let manifest = suite(#"{"tier":"release","script":"a.py"},{"tier":"secret","script":"b.py"}"#)
        let findings = NoPublicTestCheck().findings(in: try snapshot(manifest))
        #expect(findings.map(\.checkID) == ["tiers.noPublicTest"])
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.suggestedFix != nil)
    }

    @Test func noPublicTestIsQuietWithOnePublicTest() throws {
        let manifest = suite(#"{"tier":"secret","script":"a.py"},{"tier":"public","script":"b.py"}"#)
        #expect(NoPublicTestCheck().findings(in: try snapshot(manifest)).isEmpty)
    }

    @Test func noPublicTestIsQuietOnAnEmptySuite() throws {
        #expect(NoPublicTestCheck().findings(in: try snapshot(suite(""))).isEmpty)
    }

    // MARK: - points.zeroPoints

    @Test func zeroPointsNamesEachZeroPointEntry() throws {
        let manifest = suite(
            #"{"tier":"public","script":"a.py","points":0,"name":"Diagnostics"},"#
                + #"{"tier":"public","script":"b.py","points":2},"#
                + #"{"tier":"secret","script":"c.py","points":0}"#)
        let findings = ZeroPointsCheck().findings(in: try snapshot(manifest))
        #expect(findings.map(\.location) == [.suiteItem("a.py"), .suiteItem("c.py")])
        #expect(findings.allSatisfy { $0.severity == .info && $0.source == .check })
        #expect(findings.first?.message.hasPrefix("Diagnostics ") == true)
        #expect(findings.last?.message.hasPrefix("c.py ") == true)
    }

    // MARK: - The catalog

    @Test func catalogIDsAreUniqueAndDotted() {
        let ids = AuthoringCheckCatalog.ids
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.split(separator: ".").count == 2 })
    }

    @Test func catalogSortsFindingsMostSevereFirst() throws {
        let manifest = suite(
            #"{"tier":"release","script":"a.py","points":0}"#,
            extra: #","gradingMode":"browser","submissionMode":"uploadOnly""#)
        let findings = AuthoringCheckCatalog.findings(in: try snapshot(manifest))
        #expect(
            findings.map(\.checkID) == [
                "manifest.incoherent", "points.noGradedTest", "tiers.noPublicTest", "points.zeroPoints",
            ])
    }

    @Test func severityRankFollowsDeclarationOrder() {
        #expect(AuthoringFinding.Severity.allCases.map(\.rank) == [0, 1, 2])
        #expect(AuthoringFinding.Severity.error.rank < AuthoringFinding.Severity.info.rank)
    }
}
