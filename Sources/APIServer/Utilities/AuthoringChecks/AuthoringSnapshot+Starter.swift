// APIServer/Utilities/AuthoringChecks/AuthoringSnapshot+Starter.swift
//
// The join the starter checks share (#2747): each graded suite entry with its
// outcome on the starter, for entries the solution passes. Both
// `starter.passesGradedTest` and `starter.errorsInsteadOfFails` read it, and so
// does the workbench's "passes on the starter" rule
// (`InstructorSuiteOutlineBuilder`), which states the same filter.

import Core

extension AuthoringSnapshot {
    /// Each suite entry worth points that the solution passes, with its
    /// starter outcome. Empty when there is no starter run, or when the starter
    /// did not run (`StarterValidationRun.failure(of:)`): its outcomes then say
    /// nothing about the tests.
    func gradedEntriesOnStarter() -> [(entry: TestSuiteEntry, starter: TestOutcome?)] {
        guard let starterRun, StarterValidationRun.failure(of: starterRun) == nil else { return [] }
        let starter = starterRun.outcomesByScript(in: manifest)
        let solution = solutionRun?.outcomesByScript(in: manifest) ?? [:]
        return manifest.testSuites
            .filter { $0.points > 0 && solution[$0.script]?.status == .pass }
            .map { ($0, starter[$0.script]) }
    }
}
