// Core/Models/DatasetDescription.swift
//
// What a stored dataset version says about its file, for a format whose file
// is not described by a column list (docs/dataset-kinds-plan.md §5). A CSV
// version keeps its dictionary in `columns_json`; every other format stores
// one of these in `course_dataset_versions.summary_json`, so a new format
// adds a case here, not a column.
//
// The stored form is an envelope that names its format and its version:
//
//     {"descriptionVersion":1,"format":"fhirNdjson","fhirNdjson":{...}}
//
// A row written before the envelope holds a bare `FHIRDatasetSummary`; it is
// read as `.fhirNdjson`. A format or a version this server does not know
// fails to decode, and every reader treats that as "no description", rather
// than failing the page or the tool.

import Foundation

/// The description of one dataset version, by format.
public enum DatasetDescription: Equatable, Sendable {
    case fhirNdjson(FHIRDatasetSummary)

    /// The envelope version this server writes.
    public static let currentVersion = 1

    /// The format the description is of.
    public var format: DatasetFormat {
        switch self {
        case .fhirNdjson: return .fhirNdjson
        }
    }

    /// The FHIR summary, or nil for another format.
    public var fhirSummary: FHIRDatasetSummary? {
        switch self {
        case .fhirNdjson(let summary): return summary
        }
    }
}

extension DatasetDescription: Codable {
    private enum CodingKeys: String, CodingKey {
        case descriptionVersion, format, fhirNdjson
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try c.decodeIfPresent(Int.self, forKey: .descriptionVersion) else {
            // Written before the envelope: a bare FHIR summary.
            self = .fhirNdjson(try FHIRDatasetSummary(from: decoder))
            return
        }
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .descriptionVersion, in: c,
                debugDescription: "Description version \(version) is newer than this server reads.")
        }
        let format = try c.decode(DatasetFormat.self, forKey: .format)
        switch format {
        case .fhirNdjson:
            self = .fhirNdjson(try c.decode(FHIRDatasetSummary.self, forKey: .fhirNdjson))
        case .csv:
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: c,
                debugDescription: "A CSV version keeps its dictionary in its columns, not in a description.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .descriptionVersion)
        try c.encode(format, forKey: .format)
        switch self {
        case .fhirNdjson(let summary): try c.encode(summary, forKey: .fhirNdjson)
        }
    }
}
