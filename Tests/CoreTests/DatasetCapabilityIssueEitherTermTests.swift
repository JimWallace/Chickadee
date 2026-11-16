// Tests/CoreTests/DatasetCapabilityIssueEitherTermTests.swift
//
// `DatasetSpecValidation.capabilityIssue` refuses a partition setting on a
// format that cannot partition when the spec's kind is `.partition` OR it
// names a `partCount`, and a stratum setting when the kind is
// `.stratifiedSample` OR it names a `stratumColumn`. Either term alone is a
// setting the materializer would ignore, and an instructor who set it would
// believe it did something. The 2026-11-13 sweep (#3015) saw both `||`
// connectors turned into `&&` survive: no test set one term without the
// other, so a FHIR spec with only one of them saved without a word.

import Core
import Testing

@Suite struct DatasetCapabilityIssueEitherTermTests {

    private static let split =
        "'a.ndjson': a FHIR NDJSON dataset cannot be split into parts; every student receives the whole file."
    private static let stratum = "'a.ndjson': a FHIR NDJSON dataset takes no stratum column."

    @Test func aPartitionKindAloneIsRefused() {
        let spec = DatasetSpec(file: "a.ndjson", kind: .partition, format: .fhirNdjson)
        #expect(DatasetSpecValidation.capabilityIssue(with: spec) == Self.split)
    }

    @Test func aPartCountAloneIsRefused() {
        let spec = DatasetSpec(file: "a.ndjson", kind: .rowSample, partCount: 3, format: .fhirNdjson)
        #expect(DatasetSpecValidation.capabilityIssue(with: spec) == Self.split)
    }

    @Test func aStratifiedKindAloneIsRefused() {
        let spec = DatasetSpec(file: "a.ndjson", kind: .stratifiedSample, format: .fhirNdjson)
        #expect(DatasetSpecValidation.capabilityIssue(with: spec) == Self.stratum)
    }

    @Test func aStratumColumnAloneIsRefused() {
        let spec = DatasetSpec(file: "a.ndjson", kind: .rowSample, stratumColumn: "sex", format: .fhirNdjson)
        #expect(DatasetSpecValidation.capabilityIssue(with: spec) == Self.stratum)
    }

    @Test func aPlainFHIRSpecHasNoIssue() {
        #expect(DatasetSpecValidation.capabilityIssue(with: DatasetSpec(file: "a.ndjson", format: .fhirNdjson)) == nil)
    }
}
