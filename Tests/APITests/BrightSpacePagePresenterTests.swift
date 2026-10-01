// Tests/APITests/BrightSpacePagePresenterTests.swift
//
// The pure half of the LEARN page presenter: what the facts card says for a
// given connection state. The database-backed half is covered through the
// page by `InstructorLearnPageTests` and `BrightSpacePanelTests`.

import Foundation
import Testing

@testable import APIServer

@Suite struct BrightSpacePagePresenterTests {

    private func facts(
        syncEnabled: Bool = true,
        identity: BrightSpacePagePresenter.SyncIdentity = .init(name: "Prof Lee", connected: true, isMe: true),
        needsReconnect: Bool = false,
        usesServiceAccount: Bool = false,
        accountConnected: Bool = true,
        isArchived: Bool = false,
        newestAttempt: Date? = nil,
        unreachableCount: Int = 0
    ) -> BrightSpacePagePresenter.LearnPageFacts {
        BrightSpacePagePresenter.learnPageFacts(
            BrightSpacePagePresenter.LearnFactsInput(
                usesServiceAccount: usesServiceAccount,
                syncEnabled: syncEnabled,
                syncIdentity: InstructorBrightspaceContext.SyncIdentityPanel(
                    name: identity.name, hasName: identity.name != nil, isMe: identity.isMe,
                    connected: identity.connected, needsReconnect: needsReconnect),
                identity: identity,
                accountConnected: accountConnected,
                isArchived: isArchived,
                newestAttempt: newestAttempt,
                unreachableCount: unreachableCount,
                lastCheckedText: "Sep 3, 2:10 PM"),
            fmt: waterlooDateTimeFormatter())
    }

    @Test func theSyncIsHealthyOnlyWhileTheIdentityCanReachLEARN() {
        #expect(facts().syncHealthy)
        #expect(!facts(syncEnabled: false).syncHealthy)
        #expect(!facts(needsReconnect: true).syncHealthy)
        #expect(!facts(identity: .init(name: "Prof Lee", connected: false, isMe: false)).syncHealthy)
    }

    @Test func theLastSyncIsNeverUntilAnAttemptExists() {
        #expect(facts().lastSyncText == "Never")
        #expect(facts().lastSyncISO == nil)
        let attempt = Date(timeIntervalSince1970: 1_700_000_000)
        let withAttempt = facts(newestAttempt: attempt)
        #expect(withAttempt.lastSyncISO == ISO8601DateFormatter().string(from: attempt))
        #expect(withAttempt.lastSyncText != "Never")
    }

    @Test func theOrgUnitCanBeChangedByAServiceAccountOrAConnectedViewer() {
        #expect(facts(usesServiceAccount: true, accountConnected: false).canBindOrgUnit)
        #expect(facts(usesServiceAccount: false, accountConnected: true).canBindOrgUnit)
        #expect(!facts(usesServiceAccount: false, accountConnected: false).canBindOrgUnit)
        #expect(!facts(usesServiceAccount: true, isArchived: true).canBindOrgUnit)
    }

    @Test func theReadinessSummaryCountsStudentsInTheRightNumber() {
        #expect(
            facts(unreachableCount: 1).readinessSummary == "1 student can't receive grades · checked Sep 3, 2:10 PM")
        #expect(facts(unreachableCount: 3).readinessSummary.hasPrefix("3 students can't receive grades"))
        #expect(facts(unreachableCount: 0).readinessSummary.hasPrefix("0 students"))
    }
}
