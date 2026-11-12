// Core/Models/DatasetFormat.swift
//
// What kind of file a dataset is (docs/fhir-datasets-plan.md §6). The format is
// declared on the spec, never read off the bytes: the save-time checks refuse a
// spec whose file extension disagrees with it, and delivery trusts it.

/// The format of a dataset file.
///
/// - `csv`: a table with a header row. Every dataset authored before FHIR
///   support, and the decoded default.
/// - `fhirNdjson`: FHIR R4 resources, one JSON object per line, any mix of
///   resource types. The first release delivers it whole to every student
///   (docs/fhir-datasets-plan.md §11, decision 1).
public enum DatasetFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case csv
    case fhirNdjson

    /// The extension a file of this format must have, without the dot.
    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .fhirNdjson: return "ndjson"
        }
    }

    /// A short name for messages to instructors.
    public var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .fhirNdjson: return "FHIR NDJSON"
        }
    }

    /// The media type for a download of a file in this format.
    public var mediaType: String {
        switch self {
        case .csv: return "text/csv"
        case .fhirNdjson: return "application/fhir+ndjson"
        }
    }

    /// True when `filename` ends in this format's extension, ignoring case,
    /// with a name before the dot.
    public func matches(filename: String) -> Bool {
        let suffix = "." + fileExtension
        return filename.count > suffix.count && filename.lowercased().hasSuffix(suffix)
    }

    /// The selection settings a spec of this format accepts. A format whose
    /// capabilities select nothing is delivered whole, whatever the spec
    /// asks for: the save-time checks refuse each setting it lacks, and
    /// delivery never fails a student over a spec that slipped through a
    /// whole-manifest door.
    public var capabilities: DatasetCapabilities {
        switch self {
        case .csv: return .table
        // Shared first (docs/fhir-datasets-plan.md §11, decision 1);
        // sampling by patient is P5.
        case .fhirNdjson: return .whole(unitName: "patient")
        }
    }

    /// Whether a file of this format becomes a dataset only through the
    /// course library. A FHIR file is checked and summarized there; a CSV can
    /// also be marked by hand in an assignment's Files panel.
    public var entersThroughLibrary: Bool {
        switch self {
        case .csv: return false
        case .fhirNdjson: return true
        }
    }

    /// The formats a file named `filename` could be, by its extension. Today
    /// at most one; a later format that shares an extension (plain NDJSON
    /// records) makes it two, and a caller then asks which.
    public static func candidates(forFilename filename: String) -> [DatasetFormat] {
        allCases.filter { $0.matches(filename: filename) }
    }
}
