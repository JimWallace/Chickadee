// Tests/CoreTests/DatasetCapabilitiesSelectsTests.swift
//
// `DatasetCapabilities.selects` is true when ANY one setting can make a
// student's bytes differ from the file. The two shipped formats are all-on
// (CSV) or all-off (FHIR), and on those an `&&` in place of one `||` gives the
// same answer, so the 2026-11-13 sweep (#3015) saw all three connector
// mutants survive. The mixed case is the designed one: the file header says a
// format whose sampling arrives later turns on `sample` without the rest. With
// `sample && stratum`, that format would read as "delivered whole", so the
// materializer would hand every student the whole file and the capability
// message would say so. Each single setting must make `selects` true.

import Core
import Testing

@Suite struct DatasetCapabilitiesSelectsTests {

    static let singles: [(name: String, capabilities: DatasetCapabilities)] = [
        (
            "sample",
            DatasetCapabilities(sample: true, stratum: false, partition: false, transforms: false, unitName: "u")
        ),
        (
            "stratum",
            DatasetCapabilities(sample: false, stratum: true, partition: false, transforms: false, unitName: "u")
        ),
        (
            "partition",
            DatasetCapabilities(sample: false, stratum: false, partition: true, transforms: false, unitName: "u")
        ),
        (
            "transforms",
            DatasetCapabilities(sample: false, stratum: false, partition: false, transforms: true, unitName: "u")
        ),
    ]

    @Test(arguments: singles)
    func anySingleSettingSelects(name: String, capabilities: DatasetCapabilities) {
        #expect(capabilities.selects, "only \(name) is on")
    }

    @Test func noSettingDeliversTheFileWhole() {
        #expect(!DatasetCapabilities.whole(unitName: "u").selects)
    }
}
