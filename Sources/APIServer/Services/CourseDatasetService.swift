// APIServer/Services/CourseDatasetService.swift
//
// The course dataset library (docs/datasets-course-library.md, slice 2):
// create a dataset from its first version, add versions, edit what describes
// it, publish it, find where it is used, and delete it when nothing uses it.
//
// Authorization is the caller's job, as for every service here: the web routes
// and the MCP tools of later slices gate on the course role first. This file
// owns the rules about the data itself.
//
// The bytes of a version are a blob in the store that assignment versions use
// (`AssignmentVersionBlobStore`). The blob is written before the row that
// names it, which is the order the blob garbage collector's grace window
// expects, and the collector counts dataset versions as references
// (`AssignmentVersionStore.referencedBlobHashes`).

import Core
import Fluent
import Foundation

enum CourseDatasetService {

    /// The largest version a library accepts. Datasets in use are a few
    /// hundred kilobytes; this leaves room without making a version a
    /// large upload.
    static let maxVersionBytes = 16 << 20

    static let maxNameLength = 200

    /// How many times a version write retries after losing a race for its
    /// version number.
    private static let versionWriteAttempts = 3

    /// What a new dataset is called and what describes it.
    struct NewDataset: Sendable {
        var name: String
        var slug: String
        var description: String?
        var provenance: String?
        var licence: String?
    }

    /// One uploaded file.
    struct Upload: Sendable {
        var filename: String
        var bytes: Data
        var note: String?
    }

    /// A metadata edit. A nil field is left as it is. An empty or blank text
    /// field clears it, except the name, which a dataset always has.
    struct MetadataEdit: Sendable {
        var name: String?
        var description: String?
        var provenance: String?
        var licence: String?
    }

    /// The instructor prose for one column. The value type is inferred from
    /// the file and is not editable.
    struct ColumnNote: Sendable, Equatable {
        var name: String
        var description: String?
        var unit: String?
    }

    struct AddedVersion: Sendable {
        let version: APICourseDatasetVersion
        /// Columns of the previous version that the new file does not have.
        /// Their prose was dropped.
        let droppedColumns: [String]
    }

    /// One assignment, or one draft, whose manifest attaches a dataset.
    struct Usage: Sendable, Equatable {
        let testSetupID: String
        /// Nil for a draft that has no assignment row yet.
        let assignmentPublicID: String?
        let assignmentTitle: String?
        /// The attached filename in the setup zip.
        let file: String
        /// The pinned version.
        let version: Int
    }

    // MARK: - Reading

    /// The course's datasets, by name.
    static func list(courseID: UUID, on db: any Database) async throws -> [APICourseDataset] {
        try await APICourseDataset.query(on: db)
            .filter(\.$courseID == courseID)
            .sort(\.$name)
            .all()
    }

    /// Whether the course has a published dataset, of `slugs` when given.
    /// The dashboard and the upload page ask this to decide on their link
    /// to the Data page.
    static func hasPublished(courseID: UUID, slugs: Set<String>? = nil, on db: any Database) async throws -> Bool {
        if let slugs, slugs.isEmpty { return false }
        let query = APICourseDataset.query(on: db)
            .filter(\.$courseID == courseID)
            .filter(\.$isPublished == true)
        if let slugs {
            query.filter(\.$slug ~~ Array(slugs))
        }
        return try await query.first() != nil
    }

    static func find(courseID: UUID, slug: String, on db: any Database) async throws -> APICourseDataset? {
        try await APICourseDataset.query(on: db)
            .filter(\.$courseID == courseID)
            .filter(\.$slug == slug)
            .first()
    }

    /// Every version of `dataset`, oldest first.
    static func versions(of dataset: APICourseDataset, on db: any Database) async throws -> [APICourseDatasetVersion] {
        try await APICourseDatasetVersion.query(on: db)
            .filter(\.$datasetID == dataset.requireID())
            .sort(\.$version)
            .all()
    }

    static func version(
        _ number: Int, of dataset: APICourseDataset, on db: any Database
    ) async throws -> APICourseDatasetVersion? {
        try await APICourseDatasetVersion.query(on: db)
            .filter(\.$datasetID == dataset.requireID())
            .filter(\.$version == number)
            .first()
    }

    /// The bytes of one version.
    static func bytes(of version: APICourseDatasetVersion, blobs: AssignmentVersionBlobStore) throws -> Data {
        try blobs.read(version.sha256)
    }

    /// Every assignment and draft in the dataset's course whose manifest names
    /// the dataset as a source, in setup ID order.
    static func usage(of dataset: APICourseDataset, on db: any Database) async throws -> [Usage] {
        let setups = try await APITestSetup.query(on: db)
            .filter(\.$courseID == dataset.courseID)
            .sort(\.$id)
            .all()
        var found: [(setupID: String, spec: DatasetSpec, source: DatasetSource)] = []
        for setup in setups {
            guard let setupID = setup.id, let datasets = setup.decodedManifest()?.datasets else { continue }
            for spec in datasets {
                if let source = spec.source, source.slug == dataset.slug {
                    found.append((setupID, spec, source))
                }
            }
        }
        guard !found.isEmpty else { return [] }

        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$testSetupID ~~ Set(found.map(\.setupID)))
            .all()
        let assignmentBySetup = Dictionary(
            assignments.map { ($0.testSetupID, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { entry in
            let assignment = assignmentBySetup[entry.setupID]
            return Usage(
                testSetupID: entry.setupID, assignmentPublicID: assignment?.publicID,
                assignmentTitle: assignment?.title, file: entry.spec.file, version: entry.source.version)
        }
    }

    /// The newest version of each dataset, by dataset ID, in one query.
    static func newestVersions(
        of datasets: [APICourseDataset], on db: any Database
    ) async throws -> [UUID: APICourseDatasetVersion] {
        let ids = try datasets.map { try $0.requireID() }
        guard !ids.isEmpty else { return [:] }
        let current = Dictionary(
            try datasets.map { (try $0.requireID(), $0.currentVersion) }, uniquingKeysWith: { first, _ in first })
        let versions = try await APICourseDatasetVersion.query(on: db)
            .filter(\.$datasetID ~~ ids)
            .all()
        return Dictionary(
            versions.filter { current[$0.datasetID] == $0.version }.map { ($0.datasetID, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    /// How many assignments and drafts of the course attach each dataset, by
    /// slug. One read of the course's manifests, for the list page.
    static func usageCounts(courseID: UUID, on db: any Database) async throws -> [String: Int] {
        let setups = try await APITestSetup.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
        var counts: [String: Int] = [:]
        for setup in setups {
            let slugs = Set((setup.decodedManifest()?.datasets ?? []).compactMap(\.source?.slug))
            for slug in slugs {
                counts[slug, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Writing

    /// Creates a dataset whose version 1 is `upload`. The dataset starts
    /// unpublished (D8).
    static func create(
        courseID: UUID, dataset input: NewDataset, upload: Upload, blobs: AssignmentVersionBlobStore,
        on db: any Database
    ) async throws -> (dataset: APICourseDataset, version: APICourseDatasetVersion) {
        let slug = try validatedSlug(input.slug)
        let name = try validatedName(input.name)
        if try await find(courseID: courseID, slug: slug, on: db) != nil {
            throw CourseDatasetError.slugTaken(slug)
        }
        let checked = try checkedUpload(upload)
        let hash = try blobs.put(upload.bytes)

        do {
            return try await db.transaction { tx in
                let dataset = APICourseDataset(
                    courseID: courseID, slug: slug, name: name, datasetDescription: cleaned(input.description),
                    provenance: cleaned(input.provenance), licence: cleaned(input.licence), currentVersion: 1)
                try await dataset.create(on: tx)
                let version = APICourseDatasetVersion(
                    datasetID: try dataset.requireID(), version: 1, filename: checked.filename, sha256: hash,
                    sizeBytes: upload.bytes.count, rowCount: checked.profile.rowCount,
                    columns: checked.profile.columns, note: cleaned(upload.note))
                try await version.create(on: tx)
                return (dataset, version)
            }
        } catch {
            // Two creates raced for one slug, and this one lost. Any other
            // failure is not a slug clash, so it is not reported as one.
            if (error as? any DatabaseError)?.isConstraintFailure == true,
                try await find(courseID: courseID, slug: slug, on: db) != nil
            {
                throw CourseDatasetError.slugTaken(slug)
            }
            throw error
        }
    }

    /// Adds `upload` as the next version of `dataset`, with the previous
    /// version's dictionary prose carried onto it by column name.
    static func addVersion(
        to dataset: APICourseDataset, upload: Upload, blobs: AssignmentVersionBlobStore, on db: any Database
    ) async throws -> AddedVersion {
        let checked = try checkedUpload(upload)
        let hash = sha256HexDigest(upload.bytes)
        let existing = try await versions(of: dataset, on: db)
        if let same = existing.first(where: { $0.sha256 == hash }) {
            throw CourseDatasetError.duplicateVersion(of: same.version)
        }
        try blobs.put(upload.bytes)

        let carried = DatasetDictionary.carried(
            from: existing.last?.columns ?? [], onto: checked.profile.columns)
        for _ in 0..<versionWriteAttempts {
            do {
                let version = try await db.transaction { tx in
                    let datasetID = try dataset.requireID()
                    let newest =
                        try await APICourseDatasetVersion.query(on: tx)
                        .filter(\.$datasetID == datasetID)
                        .max(\.$version) ?? 0
                    let version = APICourseDatasetVersion(
                        datasetID: datasetID, version: newest + 1, filename: checked.filename, sha256: hash,
                        sizeBytes: upload.bytes.count, rowCount: checked.profile.rowCount,
                        columns: carried.columns, note: cleaned(upload.note))
                    try await version.create(on: tx)
                    dataset.currentVersion = newest + 1
                    try await dataset.update(on: tx)
                    return version
                }
                return AddedVersion(version: version, droppedColumns: carried.droppedColumns)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                // Another upload took this version number; read the newest again.
                continue
            }
        }
        throw CourseDatasetError.versionNumberContended
    }

    /// Applies `edit` to the dataset's own fields.
    static func updateMetadata(
        _ dataset: APICourseDataset, edit: MetadataEdit, on db: any Database
    ) async throws {
        // Every check runs before the model changes, so a refused edit leaves
        // the caller's object as it was.
        let name = try edit.name.map(validatedName) ?? dataset.name
        let provenance = edit.provenance.map(cleaned) ?? dataset.provenance
        let licence = edit.licence.map(cleaned) ?? dataset.licence
        if dataset.isPublished, cleaned(provenance) == nil || cleaned(licence) == nil {
            throw CourseDatasetError.governanceRequiredWhilePublished
        }
        dataset.name = name
        if let description = edit.description { dataset.datasetDescription = cleaned(description) }
        dataset.provenance = provenance
        dataset.licence = licence
        try await dataset.update(on: db)
    }

    /// Replaces the prose of version `number`'s dictionary. A column the notes
    /// do not name loses its prose. The value types stay as inferred.
    static func updateDictionary(
        _ dataset: APICourseDataset, version number: Int, notes: [ColumnNote], on db: any Database
    ) async throws -> APICourseDatasetVersion {
        guard let version = try await version(number, of: dataset, on: db) else {
            throw CourseDatasetError.unknownVersion(number)
        }
        let columns = version.columns
        let proposed = notes.map { DatasetColumn(name: $0.name, valueType: .text) }
        if let issue = DatasetDictionary.editIssue(proposed, header: columns.map(\.name)) {
            throw CourseDatasetError.dictionary(issue)
        }
        let byName = Dictionary(notes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        version.columns = columns.map { column in
            DatasetColumn(
                name: column.name, valueType: column.valueType,
                description: cleaned(byName[column.name]?.description), unit: cleaned(byName[column.name]?.unit))
        }
        try await version.update(on: db)
        return version
    }

    /// Publishes or unpublishes `dataset`. Publishing needs a provenance and a
    /// licence (D8).
    static func setPublished(_ dataset: APICourseDataset, _ published: Bool, on db: any Database) async throws {
        if published, !hasGovernance(dataset) {
            throw CourseDatasetError.missingGovernance
        }
        dataset.isPublished = published
        try await dataset.update(on: db)
    }

    /// Deletes `dataset` and its versions. Refused while any assignment or
    /// draft attaches it. The blobs stay until the next blob collection.
    static func delete(_ dataset: APICourseDataset, on db: any Database) async throws {
        let users = try await usage(of: dataset, on: db)
        guard users.isEmpty else {
            throw CourseDatasetError.inUse(
                by: users.map { usage in usage.assignmentTitle.map { "'\($0)'" } ?? "draft \(usage.testSetupID)" })
        }
        try await db.transaction { tx in
            try await APICourseDatasetVersion.query(on: tx)
                .filter(\.$datasetID == dataset.requireID())
                .delete()
            try await dataset.delete(on: tx)
        }
    }

    // MARK: - Rules

    static func hasGovernance(_ dataset: APICourseDataset) -> Bool {
        cleaned(dataset.provenance) != nil && cleaned(dataset.licence) != nil
    }

    /// 1 to 64 lowercase letters, digits and hyphens, starting and ending with
    /// a letter or a digit. A computed property because `Regex` is not
    /// `Sendable`.
    private static var slugPattern: Regex<Substring> {
        /[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?/
    }

    static func validatedSlug(_ raw: String) throws -> String {
        let slug = raw.trimmingCharacters(in: .whitespaces)
        guard slug.wholeMatch(of: slugPattern) != nil else { throw CourseDatasetError.invalidSlug(raw) }
        return slug
    }

    /// A slug made from a dataset name: lowercase letters and digits, with
    /// one hyphen for each run of other characters. Empty when the name has
    /// no letter or digit, so `validatedSlug` refuses it.
    static func suggestedSlug(from name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        let capped = String(slug.prefix(64))
        return capped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func validatedName(_ raw: String) throws -> String {
        guard let name = cleaned(raw), name.count <= maxNameLength else { throw CourseDatasetError.invalidName }
        return name
    }

    /// A bare filename ending in `.csv`, which is the only format the
    /// materializer slices.
    static func validatedFilename(_ raw: String) throws -> String {
        guard let name = FilenameSafety.bareFilename(raw), name == raw,
            name.lowercased().hasSuffix(".csv"), name.count > ".csv".count
        else { throw CourseDatasetError.invalidFilename(raw) }
        return name
    }

    private static func checkedUpload(
        _ upload: Upload
    ) throws -> (filename: String, profile: DatasetDictionary.Profile) {
        let filename = try validatedFilename(upload.filename)
        guard upload.bytes.count <= maxVersionBytes else {
            throw CourseDatasetError.tooLarge(sizeBytes: upload.bytes.count, limitBytes: maxVersionBytes)
        }
        guard let text = String(data: upload.bytes, encoding: .utf8) else { throw CourseDatasetError.notUTF8 }
        switch DatasetDictionary.profile(csv: text) {
        case .success(let profile): return (filename, profile)
        case .failure(let error): throw CourseDatasetError.notATable(error)
        }
    }

    /// Trimmed text, or nil when nothing is left.
    static func cleaned(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
