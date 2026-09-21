// Tests/APITests/RunnerActivityGateTests.swift
//
// The implicit activity-match gate (RunnerActivityGate): fails open for an
// assignment that stages no opponent and for a profile-less runner, refuses
// a profile without `activity-match`, admits one with it — and answers for
// every kind through the opponent axis, never the kind's name.

import Core
import Testing

@testable import APIServer

@Suite struct RunnerActivityGateTests {

    private func manifest(_ activity: ClassActivity?) -> TestProperties {
        TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], activity: activity)
    }

    private func profile(capabilities: [String]) -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: "linux", architecture: "x86_64",
            languageVersions: [], capabilities: capabilities.map { RunnerCapability(name: $0) })
    }

    @Test func anOrdinaryAssignmentIsClaimableByAnyone() {
        let result = RunnerActivityGate.evaluate(
            runnerProfile: profile(capabilities: []), manifest: manifest(nil))
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    /// Every kind answers through its opponent source: a kind with none is
    /// claimable by an old build, a kind with one is not.
    @Test(arguments: ActivityKind.allCases)
    func aProfileWithoutTheCapabilityIsRefusedExactlyWhenTheKindStagesAnOpponent(kind: ActivityKind) {
        let result = RunnerActivityGate.evaluate(
            runnerProfile: profile(capabilities: ["shell-bash"]),
            manifest: manifest(ClassActivity(kind: kind, opponentFile: "bot.py")))
        #expect(result.isCompatible == !kind.opponentSource.stagesAnOpponent)
        if !result.isCompatible {
            #expect(result.reasons.count == 1)
            #expect(result.reasons.first?.contains("activity-match") == true)
        }
    }

    @Test func aProfileWithTheCapabilityIsAdmitted() {
        #expect(
            RunnerActivityGate.evaluate(
                runnerProfile: profile(capabilities: ["Activity-Match"]),
                manifest: manifest(ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py"))
            ).isCompatible)
    }

    /// A bot kind whose file is not chosen stages nothing and stays claimable
    /// by every build — the slice-1 path, unchanged.
    @Test func aBotKindWithNoFileChosenIsClaimableByAnyone() {
        #expect(
            RunnerActivityGate.evaluate(
                runnerProfile: profile(capabilities: []),
                manifest: manifest(ClassActivity(kind: .beatTheInstructor))
            ).isCompatible)
    }

    /// Discovery off is an operator's choice; refusing would stop that runner
    /// claiming anything. An old runner still has discovery on and is caught.
    @Test func aRunnerWithNoProfileIsNotBlocked() {
        #expect(
            RunnerActivityGate.evaluate(
                runnerProfile: nil, manifest: manifest(ClassActivity(kind: .beatTheInstructor))
            ).isCompatible)
    }
}
