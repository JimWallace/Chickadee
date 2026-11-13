// Core/Models/DatasetCapabilities.swift
//
// What a dataset's format lets a spec do (docs/dataset-kinds-plan.md §6).
// Every reader that used to ask "is this a CSV?" asks one of these instead, so
// a new format answers each question once, in `DatasetFormat.capabilities`,
// and a format whose sampling arrives later (FHIR, P5) turns on `sample`
// without turning on everything else.

/// The selection settings a dataset file accepts.
public struct DatasetCapabilities: Codable, Equatable, Sendable {
    /// A per-student sample of units (`sampleSize`).
    public let sample: Bool
    /// A sample balanced across a column's values (`stratumColumn`).
    public let stratum: Bool
    /// A split into parts dealt to students (`partCount`).
    public let partition: Bool
    /// Derivation steps applied after selection (`transforms`).
    public let transforms: Bool
    /// What one unit of selection is called, for prose: "row", "patient".
    public let unitName: String

    public init(sample: Bool, stratum: Bool, partition: Bool, transforms: Bool, unitName: String) {
        self.sample = sample
        self.stratum = stratum
        self.partition = partition
        self.transforms = transforms
        self.unitName = unitName
    }

    /// True when any setting can make a student's bytes differ from the file.
    /// False means the materializer delivers the file whole.
    public var selects: Bool { sample || stratum || partition || transforms }

    /// Every setting: a CSV table, whose unit is a row.
    public static let table = DatasetCapabilities(
        sample: true, stratum: true, partition: true, transforms: true, unitName: "row")

    /// No setting: every student receives the whole file.
    public static func whole(unitName: String) -> DatasetCapabilities {
        DatasetCapabilities(sample: false, stratum: false, partition: false, transforms: false, unitName: unitName)
    }
}
