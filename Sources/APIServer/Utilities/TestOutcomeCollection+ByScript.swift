// APIServer/Utilities/TestOutcomeCollection+ByScript.swift
//
// Joins a run's outcomes to the manifest's suite entries. The worker reports a
// test by its script stem and the browser by its filename, so each entry is
// looked up both ways.

import Core

extension TestOutcomeCollection {
    /// Each suite entry's outcome in this run, keyed by the entry's script
    /// filename. An entry with no outcome is absent.
    func outcomesByScript(in manifest: TestProperties) -> [String: TestOutcome] {
        let byName = Dictionary(outcomes.map { ($0.testName, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: TestOutcome] = [:]
        for entry in manifest.testSuites {
            result[entry.script] = byName[entry.script] ?? byName[runnerScriptStem(entry.script)]
        }
        return result
    }
}
