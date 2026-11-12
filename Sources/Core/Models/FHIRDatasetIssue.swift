// Core/Models/FHIRDatasetIssue.swift
//
// Why a FHIR NDJSON file was refused (docs/fhir-datasets-plan.md §3, F2). Each
// case names the physical line, counted from 1, so an instructor can find it.

/// A structural problem in a FHIR NDJSON dataset file.
public enum FHIRDatasetIssue: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file has no line that holds anything but whitespace.
    case empty
    /// A line that is not a JSON object.
    case notAnObject(line: Int)
    /// A line with no `resourceType`, or one that is not a non-empty string.
    case missingResourceType(line: Int)
    /// A line with no `id`, or one that is not a non-empty string.
    case missingID(line: Int, resourceType: String)
    /// The same `resourceType` and `id` on two lines.
    case duplicateResource(resourceType: String, id: String, line: Int, firstLine: Int)

    public var description: String {
        switch self {
        case .empty:
            return "the file holds no FHIR resources. Put one resource on each line."
        case .notAnObject(let line):
            return "line \(line) is not a JSON object. Each line must hold one FHIR resource."
        case .missingResourceType(let line):
            return "line \(line) has no resourceType. Each resource needs one, such as \"Patient\" or "
                + "\"Observation\"."
        case .missingID(let line, let resourceType):
            return "line \(line) is a \(resourceType) with no id. Each resource needs an id."
        case .duplicateResource(let resourceType, let id, let line, let firstLine):
            return "line \(line) repeats \(resourceType)/\(id), which line \(firstLine) already holds."
        }
    }
}
