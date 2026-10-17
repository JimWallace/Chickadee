// Core/Models/DatasetColumn.swift
//
// One column of a course library dataset's data dictionary
// (docs/datasets-course-library.md, D7). The name and the value type come from
// the file; the description and the unit are instructor prose. The dictionary
// is for people: it feeds the student Data page and MCP `get_dataset`, and it
// never changes grading.

/// One column of a dataset version, as its data dictionary describes it.
public struct DatasetColumn: Codable, Sendable, Equatable {

    /// The kind of value a column holds, inferred from a bounded sample of its
    /// rows when a version is uploaded. A hint for the reader, not a contract
    /// that anything enforces.
    public enum ValueType: String, Codable, Sendable, Equatable, CaseIterable {
        case integer
        case number
        case boolean
        case date
        case text
    }

    /// The header name, exactly as the file spells it.
    public let name: String
    public let valueType: ValueType
    /// What the column means, written by the instructor.
    public var description: String?
    /// The unit of the values, for example "mmHg", written by the instructor.
    public var unit: String?

    public init(name: String, valueType: ValueType, description: String? = nil, unit: String? = nil) {
        self.name = name
        self.valueType = valueType
        self.description = description
        self.unit = unit
    }
}
