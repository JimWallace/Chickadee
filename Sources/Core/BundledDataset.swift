// Core/BundledDataset.swift
//
// One course dataset library entry carried in a course bundle
// (docs/datasets-course-library.md §4.8), with its versions. A bundle that
// carries datasets is schemaVersion 2, or 3 when one of them is not a CSV
// (docs/fhir-datasets-plan.md §6); the bytes of each version are in the ZIP at
// `datasets/<sha256>`, so two versions with one hash share one file.

import Foundation

public struct BundledDataset: Codable, Sendable, Equatable {
    public let slug: String
    public let name: String
    public let description: String?
    public let provenance: String?
    public let licence: String?
    public let isPublished: Bool
    public let currentVersion: Int
    /// Oldest first.
    public let versions: [BundledDatasetVersion]
    /// The format of every version. Absent from a version 2 bundle, which
    /// reads as CSV, and written only when it is not CSV, so a bundle of CSV
    /// datasets keeps the bytes a version 2 bundle had.
    public let format: DatasetFormat

    public init(
        slug: String, name: String, description: String?, provenance: String?, licence: String?,
        isPublished: Bool, currentVersion: Int, versions: [BundledDatasetVersion], format: DatasetFormat = .csv
    ) {
        self.format = format
        self.slug = slug
        self.name = name
        self.description = description
        self.provenance = provenance
        self.licence = licence
        self.isPublished = isPublished
        self.currentVersion = currentVersion
        self.versions = versions
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name, description, provenance, licence, isPublished, currentVersion, versions, format
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        provenance = try c.decodeIfPresent(String.self, forKey: .provenance)
        licence = try c.decodeIfPresent(String.self, forKey: .licence)
        isPublished = try c.decode(Bool.self, forKey: .isPublished)
        currentVersion = try c.decode(Int.self, forKey: .currentVersion)
        versions = try c.decode([BundledDatasetVersion].self, forKey: .versions)
        // An unknown format is refused by name, so a later format needs no
        // new bundle schemaVersion: version 3 means "datasets carry a
        // format", and a reader that does not know one says which
        // (docs/dataset-kinds-plan.md §5).
        let rawFormat = try c.decodeIfPresent(String.self, forKey: .format)
        if let rawFormat, DatasetFormat(rawValue: rawFormat) == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: c,
                debugDescription: "The dataset '\(slug)' has the format '\(rawFormat)', which this server does not "
                    + "know. Import the bundle into the server that exported it, or a newer one.")
        }
        format = rawFormat.flatMap(DatasetFormat.init(rawValue:)) ?? .csv
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(provenance, forKey: .provenance)
        try c.encodeIfPresent(licence, forKey: .licence)
        try c.encode(isPublished, forKey: .isPublished)
        try c.encode(currentVersion, forKey: .currentVersion)
        try c.encode(versions, forKey: .versions)
        if format != .csv { try c.encode(format, forKey: .format) }
    }
}

/// One version of a `BundledDataset`.
public struct BundledDatasetVersion: Codable, Sendable, Equatable {
    public let version: Int
    public let filename: String
    /// The SHA-256 of the bytes, lowercase hex. The import checks the file
    /// against it.
    public let sha256: String
    public let sizeBytes: Int
    public let rowCount: Int
    public let columns: [DatasetColumn]
    public let note: String?
    /// The summary of a FHIR version, carried for the instructor's dictionary
    /// prose and example pick; the import recomputes its facts from the
    /// bytes. Nil, and not encoded, for a CSV version, so a CSV bundle keeps
    /// its bytes.
    public let summary: FHIRDatasetSummary?

    /// Relative path within the bundle ZIP.
    public var bundleFilename: String { "datasets/\(sha256)" }

    public init(
        version: Int, filename: String, sha256: String, sizeBytes: Int, rowCount: Int, columns: [DatasetColumn],
        note: String?, summary: FHIRDatasetSummary? = nil
    ) {
        self.summary = summary
        self.version = version
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.rowCount = rowCount
        self.columns = columns
        self.note = note
    }
}
