// APIServer/Services/CourseDatasetService+Lifecycle.swift
//
// The course dataset library through a course's lifecycle
// (docs/datasets-course-library.md §4.8): a course clone copies the library,
// and a course bundle carries it (bundle schemaVersion 2). A course delete
// needs nothing here: the library rows cascade with the course, and the blob
// collector counts every version as a reference until its row is gone.

import Core
import Fluent
import Foundation

extension CourseDatasetService {

    /// Copies every dataset of `sourceCourseID`, with all its versions, into
    /// `targetCourseID`, and returns how many datasets were copied.
    ///
    /// Only rows are written. A version's bytes are a blob named by their
    /// hash, so the copy shares them. The slugs and version numbers stay the
    /// same, so the `source` of each cloned assignment still names a version
    /// in the new course (D10). A course clone must therefore copy the library
    /// before it copies the assignments, whose manifests it reconciles against
    /// the new course's library.
    @discardableResult
    static func copyLibrary(
        from sourceCourseID: UUID, to targetCourseID: UUID, on db: any Database
    ) async throws -> Int {
        let datasets = try await list(courseID: sourceCourseID, on: db)
        for dataset in datasets {
            let copy = APICourseDataset(
                courseID: targetCourseID, slug: dataset.slug, name: dataset.name,
                datasetDescription: dataset.datasetDescription, provenance: dataset.provenance,
                licence: dataset.licence, isPublished: dataset.isPublished, currentVersion: dataset.currentVersion)
            try await copy.create(on: db)
            let copyID = try copy.requireID()
            for version in try await versions(of: dataset, on: db) {
                try await APICourseDatasetVersion(
                    datasetID: copyID, version: version.version, filename: version.filename,
                    sha256: version.sha256, sizeBytes: version.sizeBytes, rowCount: version.rowCount,
                    columns: version.columns, note: version.note
                ).create(on: db)
            }
        }
        return datasets.count
    }

    // MARK: - Course bundle

    /// The library of `courseID` as a bundle carries it, by name.
    static func bundledLibrary(courseID: UUID, on db: any Database) async throws -> [BundledDataset] {
        var bundled: [BundledDataset] = []
        for dataset in try await list(courseID: courseID, on: db) {
            let versions = try await versions(of: dataset, on: db).map {
                BundledDatasetVersion(
                    version: $0.version, filename: $0.filename, sha256: $0.sha256, sizeBytes: $0.sizeBytes,
                    rowCount: $0.rowCount, columns: $0.columns, note: $0.note)
            }
            bundled.append(
                BundledDataset(
                    slug: dataset.slug, name: dataset.name, description: dataset.datasetDescription,
                    provenance: dataset.provenance, licence: dataset.licence, isPublished: dataset.isPublished,
                    currentVersion: dataset.currentVersion, versions: versions))
        }
        return bundled
    }

    /// Creates the bundled `datasets` in `courseID`, with the bytes of each
    /// version from `bytes(_:)`, and returns how many datasets it created.
    ///
    /// Each version's bytes must hash to the hash the bundle names, so a
    /// bundle cannot claim a version it does not carry. Slugs, version
    /// numbers and sizes are checked before any row is written, so a malformed
    /// bundle is refused by name and not by a unique index. The blobs are
    /// written before the rows; a failed import leaves them for the collector,
    /// as a failed upload does. A course bundle import runs this before it
    /// creates the test setups, whose manifests it reconciles against the
    /// library.
    @discardableResult
    static func importBundledLibrary(
        _ datasets: [BundledDataset], courseID: UUID,
        bytes: @escaping @Sendable (BundledDatasetVersion) throws -> Data,
        blobs: AssignmentVersionBlobStore, on db: any Database
    ) async throws -> Int {
        let checked = try checkedBundledLibrary(datasets)
        for (bundled, slug, _) in checked {
            for version in bundled.versions {
                // Reading, hashing and storing a version is file work, so it
                // runs off the cooperative pool.
                let matches = try await runBlocking {
                    let data = try bytes(version)
                    guard sha256HexDigest(data) == version.sha256, data.count == version.sizeBytes else {
                        return false
                    }
                    try blobs.put(data)
                    return true
                }
                guard matches else {
                    throw CourseDatasetError.bundledVersionMismatch(slug: slug, version: version.version)
                }
            }
        }
        for (bundled, slug, name) in checked {
            let dataset = APICourseDataset(
                courseID: courseID, slug: slug, name: name, datasetDescription: cleaned(bundled.description),
                provenance: cleaned(bundled.provenance), licence: cleaned(bundled.licence),
                isPublished: bundled.isPublished, currentVersion: bundled.versions.map(\.version).max() ?? 1)
            try await dataset.create(on: db)
            let datasetID = try dataset.requireID()
            for version in bundled.versions {
                try await APICourseDatasetVersion(
                    datasetID: datasetID, version: version.version, filename: try validatedFilename(version.filename),
                    sha256: version.sha256, sizeBytes: version.sizeBytes, rowCount: version.rowCount,
                    columns: version.columns, note: cleaned(version.note)
                ).create(on: db)
            }
        }
        return checked.count
    }

    /// Each bundled dataset with its checked slug and name, or the refusal
    /// of the first one that cannot be stored: a repeated slug, no version, a
    /// repeated or non-positive version number, or a version over the size
    /// limit.
    private static func checkedBundledLibrary(
        _ datasets: [BundledDataset]
    ) throws -> [(bundled: BundledDataset, slug: String, name: String)] {
        var slugs: Set<String> = []
        return try datasets.map { bundled in
            let slug = try validatedSlug(bundled.slug)
            let name = try validatedName(bundled.name)
            guard slugs.insert(slug).inserted else { throw CourseDatasetError.slugTaken(slug) }
            let numbers = bundled.versions.map(\.version)
            guard !numbers.isEmpty else { throw CourseDatasetError.bundledDatasetEmpty(slug) }
            guard Set(numbers).count == numbers.count, numbers.allSatisfy({ $0 >= 1 }) else {
                throw CourseDatasetError.bundledVersionNumbers(slug)
            }
            for version in bundled.versions where version.sizeBytes > maxVersionBytes {
                throw CourseDatasetError.tooLarge(sizeBytes: version.sizeBytes, limitBytes: maxVersionBytes)
            }
            return (bundled, slug, name)
        }
    }
}
