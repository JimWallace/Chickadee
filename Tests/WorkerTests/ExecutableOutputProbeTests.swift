// Tests/WorkerTests/ExecutableOutputProbeTests.swift
//
// One fact about compiled output: `LanguageDescriptor.executableOutputProbe`
// (#2714). `capabilityRequiresExecutableOutput` derives from it, and the
// runner's exec probe reads it. Before, the flag and the probe program were
// two copies, and a language that set the flag with no program was advertised
// with nothing checked.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct ExecutableOutputProbeTests {

    /// Every language that needs executable output has a probe program, and
    /// no other language has one.
    @Test(arguments: AssignmentLanguage.allCases)
    func needingExecutableOutputMeansHavingAProbe(language: AssignmentLanguage) {
        let descriptor = language.descriptor
        #expect(descriptor.capabilityRequiresExecutableOutput == (descriptor.executableOutputProbe != nil))
    }

    /// The runner probes with the descriptor's program, not a copy of its own.
    @Test(arguments: AssignmentLanguage.allCases)
    func runnerReadsTheDescriptorProbe(language: AssignmentLanguage) {
        #expect(RunnerProfileDetector.execProbeProgram(for: language) == language.descriptor.executableOutputProbe)
    }

    /// A probe is a source file in its own language, with a body to compile.
    @Test(arguments: AssignmentLanguage.allCases.filter { $0.descriptor.executableOutputProbe != nil })
    func probeIsASourceFileOfItsLanguage(language: AssignmentLanguage) throws {
        let probe = try #require(language.descriptor.executableOutputProbe)
        #expect(probe.filename.hasSuffix(".\(language.descriptor.sourceFileExtension)"))
        #expect(!probe.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
