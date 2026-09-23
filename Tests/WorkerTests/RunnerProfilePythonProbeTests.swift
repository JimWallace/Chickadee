// Tests/WorkerTests/RunnerProfilePythonProbeTests.swift
//
// The Python module probes (numpy, pandas, scipy, matplotlib) run exactly when
// the host has Python. The mutation sweep of 2026-09-22 (#1574) flipped the
// `==` in that rule to `!=` and nothing failed: every CI host has every
// interpreter, so "Python is present" and "some other language is present"
// are both true there. On a Python-only runner the flipped rule advertised no
// modules, and a job needing pandas would never be routed to it.

import Core
import Testing

@testable import chickadee_runner

@Suite struct RunnerProfilePythonProbeTests {

    private static func version(_ language: AssignmentLanguage) -> LanguageVersion {
        LanguageVersion(language: language.capabilityName, version: "1.0")
    }

    @Test func aPythonOnlyHostProbesItsModules() {
        #expect(RunnerProfileDetector.probesPythonModules(given: [Self.version(.python)]))
    }

    @Test func aHostWithoutPythonDoesNotProbeThem() {
        #expect(!RunnerProfileDetector.probesPythonModules(given: [Self.version(.r), Self.version(.lua)]))
        #expect(!RunnerProfileDetector.probesPythonModules(given: []))
    }
}
