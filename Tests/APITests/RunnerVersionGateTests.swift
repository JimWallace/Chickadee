// Tests/APITests/RunnerVersionGateTests.swift
//
// Unit tests for the manifest minimumRunnerVersion gate (RunnerVersionGate):
// a nil/blank minimum short-circuits without parsing the runner version (the
// property that keeps un-gated assignments — and non-semver mock runners —
// unaffected), the numeric comparison, fail-closed on an unparseable version
// when a gate is set, isParseable, and the combine() merge used at the claim
// seam.

import Core
import Testing

@testable import APIServer

@Suite struct RunnerVersionGateTests {

    @Test func nilMinimumIsCompatibleWithoutParsingRunnerVersion() {
        // A non-semver runner version must still pass when there's no gate — the
        // short-circuit is what keeps existing/mock runners unaffected.
        let result = RunnerVersionGate.evaluate(
            runnerVersion: "runner/1.0", minimumRunnerVersion: nil)
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    @Test func blankMinimumIsCompatible() {
        #expect(
            RunnerVersionGate.evaluate(runnerVersion: "0.4.0", minimumRunnerVersion: "   ").isCompatible)
        #expect(
            RunnerVersionGate.evaluate(runnerVersion: "0.4.0", minimumRunnerVersion: "").isCompatible)
    }

    @Test func runnerAtOrAboveMinimumIsCompatible() {
        #expect(
            RunnerVersionGate.evaluate(runnerVersion: "0.5.0", minimumRunnerVersion: "0.5.0").isCompatible)
        #expect(
            RunnerVersionGate.evaluate(runnerVersion: "0.6.1", minimumRunnerVersion: "0.5.0").isCompatible)
        #expect(
            RunnerVersionGate.evaluate(runnerVersion: "1.0.0", minimumRunnerVersion: "0.5.0").isCompatible)
    }

    @Test func runnerBelowMinimumIsIncompatibleWithReason() {
        let result = RunnerVersionGate.evaluate(
            runnerVersion: "0.4.639", minimumRunnerVersion: "0.5.0")
        #expect(!result.isCompatible)
        #expect(result.reasons.contains { $0.contains("0.4.639") && $0.contains("0.5.0") })
    }

    @Test func unparseableRunnerVersionFailsClosed() {
        let result = RunnerVersionGate.evaluate(
            runnerVersion: "runner/1.0", minimumRunnerVersion: "0.5.0")
        #expect(!result.isCompatible)
        #expect(result.reasons.contains { $0.contains("unparseable") })
    }

    @Test func isParseableMatchesVersionComparator() {
        #expect(RunnerVersionGate.isParseable("0.5.0"))
        #expect(RunnerVersionGate.isParseable("1.2.3.4"))
        #expect(!RunnerVersionGate.isParseable("runner/1.0"))
        #expect(!RunnerVersionGate.isParseable(""))
        #expect(!RunnerVersionGate.isParseable("v1.2"))
    }

    @Test func combineMergesCompatibilityAndReasons() {
        let ok = CompatibilityResult(isCompatible: true)
        #expect(RunnerVersionGate.combine(ok, ok).isCompatible)

        let merged = RunnerVersionGate.combine(
            CompatibilityResult(isCompatible: false, reasons: ["a"]),
            CompatibilityResult(isCompatible: false, reasons: ["nope"]))
        #expect(!merged.isCompatible)
        #expect(merged.reasons == ["a", "nope"])
    }
}
