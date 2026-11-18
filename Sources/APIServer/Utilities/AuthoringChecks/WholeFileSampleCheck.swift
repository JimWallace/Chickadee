// APIServer/Utilities/AuthoringChecks/WholeFileSampleCheck.swift
//
// Reports a dataset spec whose sample covers its whole file. Every student
// then receives the whole file, but `DatasetDeliveryMode` reads only the spec,
// so each student's editor stores a private copy of the same bytes instead of
// one link (docs/dataset-shared-delivery.md, "Whole-file samples"). A save
// stores such a sample as none, so this finds one saved before that rule, or
// written by a door that does not normalize.

import Core

struct WholeFileSampleCheck: AuthoringCheck {
    static let id = "datasets.wholeFilePerStudent"
    static let severity = AuthoringFinding.Severity.warning

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        snapshot.wholeFileSamples.map { sample in
            finding(at: AuthoringFinding.Location(kind: .file, reference: sample.file), sample.message, fix: sample.fix)
        }
    }
}
