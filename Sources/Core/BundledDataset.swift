// Core/BundledDataset.swift
//
// One course dataset library entry carried in a course bundle
// (docs/datasets-course-library.md §4.8), with its versions. A bundle that
// carries datasets is schemaVersion 2; the bytes of each version are in the
// ZIP at `datasets/<sha256>`, so two versions with one hash share one file.

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

    public init(
        slug: String, name: String, description: String?, provenance: String?, licence: String?,
        isPublished: Bool, currentVersion: Int, versions: [BundledDatasetVersion]
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.provenance = provenance
        self.licence = licence
        self.isPublished = isPublished
        self.currentVersion = currentVersion
        self.versions = versions
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

    /// Relative path within the bundle ZIP.
    public var bundleFilename: String { "datasets/\(sha256)" }

    public init(
        version: Int, filename: String, sha256: String, sizeBytes: Int, rowCount: Int, columns: [DatasetColumn],
        note: String?
    ) {
        self.version = version
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.rowCount = rowCount
        self.columns = columns
        self.note = note
    }
}
