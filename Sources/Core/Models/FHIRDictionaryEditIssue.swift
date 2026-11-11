// Core/Models/FHIRDictionaryEditIssue.swift
//
// Why an edit of a FHIR data dictionary was refused
// (docs/fhir-datasets-plan.md §5). The edits are in
// `FHIRDatasetSummary+Dictionary.swift`.

/// Why an edit of a FHIR data dictionary was refused.
public enum FHIRDictionaryEditIssue: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file has no resource of this type.
    case unknownResourceType(String)
    /// The summary lists no such code.
    case unknownCode(FHIRDatasetSummary.CodeKey)
    /// The file has no such resource, or its line is too long to show.
    case unknownExample(resourceType: String, id: String)
    /// One edit describes the same type or code twice.
    case describedTwice(String)
    /// A description longer than `FHIRDatasetSummary.maxDescriptionCharacters`.
    case tooLong(String)

    public var description: String {
        switch self {
        case .unknownResourceType(let type):
            return "The file has no \(type) resources."
        case .unknownCode(let key):
            return "The file has no \(FHIRDatasetSummary.entryName(key))."
        case .describedTwice(let entry):
            return "The dictionary describes \(entry) more than once."
        case .tooLong(let entry):
            return "The description of \(entry) is longer than "
                + "\(FHIRDatasetSummary.maxDescriptionCharacters) characters."
        case .unknownExample(let type, let id):
            return "The file has no \(type)/\(id) of at most \(FHIRDatasetSummary.maxExampleBytes / 1024) KB "
                + "to show as the example."
        }
    }
}
