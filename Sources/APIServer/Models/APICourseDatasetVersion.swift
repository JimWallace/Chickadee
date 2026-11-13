// APIServer/Models/APICourseDatasetVersion.swift
//
// One uploaded version of a course library dataset
// (docs/datasets-course-library.md). The bytes are the content-addressed blob
// named by `sha256`; the row holds the facts about them and the data
// dictionary. A version is never edited after upload, except for the prose in
// its dictionary.

import Core
import Fluent
import Foundation
import Vapor

final class APICourseDatasetVersion: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_dataset_versions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "dataset_id")
    var datasetID: UUID

    @Field(key: "version")
    var version: Int

    /// The filename an attachment uses unless it names another.
    @Field(key: "filename")
    var filename: String

    /// The blob hash: 64 lowercase hex characters.
    @Field(key: "sha256")
    var sha256: String

    @Field(key: "size_bytes")
    var sizeBytes: Int

    /// Data rows, not counting the header. For a FHIR version, the number of
    /// Patient resources.
    @Field(key: "row_count")
    var rowCount: Int

    /// JSON-encoded `[DatasetColumn]`. Read through `columns`. `[]` for a FHIR
    /// version, which has no columns.
    @Field(key: "columns_json")
    var columnsJSON: String

    /// What changed in this version, written by the instructor.
    @OptionalField(key: "note")
    var note: String?

    /// The JSON-encoded `DatasetDescription` of a version whose format is not
    /// described by columns (FHIR); nil for a CSV version. Read through
    /// `description`. A row written before the envelope holds a bare FHIR
    /// summary, which reads the same (docs/dataset-kinds-plan.md §5).
    @OptionalField(key: "summary_json")
    var summaryJSON: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// The version's description. A stored value that does not decode, such
    /// as one a newer server wrote, reads as nil rather than failing the read.
    var datasetDescription: DatasetDescription? {
        get {
            summaryJSON.flatMap { try? JSONDecoder().decode(DatasetDescription.self, from: Data($0.utf8)) }
        }
        set { summaryJSON = newValue.flatMap(Self.encodeDescription) }
    }

    /// The FHIR summary, when the description is one
    /// (docs/fhir-datasets-plan.md §5).
    var summary: FHIRDatasetSummary? {
        get { datasetDescription?.fhirSummary }
        set { datasetDescription = newValue.map(DatasetDescription.fhirNdjson) }
    }

    /// The data dictionary. A stored value that does not decode reads as no
    /// columns, rather than failing the read.
    var columns: [DatasetColumn] {
        get {
            (try? JSONDecoder().decode([DatasetColumn].self, from: Data(columnsJSON.utf8))) ?? []
        }
        set { columnsJSON = Self.encodeColumns(newValue) }
    }

    init() {}

    init(
        id: UUID? = nil, datasetID: UUID, version: Int, filename: String, sha256: String, sizeBytes: Int,
        rowCount: Int, columns: [DatasetColumn], description: DatasetDescription? = nil, note: String? = nil
    ) {
        self.id = id
        self.datasetID = datasetID
        self.version = version
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.rowCount = rowCount
        self.columnsJSON = Self.encodeColumns(columns)
        self.summaryJSON = description.flatMap(Self.encodeDescription)
        self.note = note
    }

    static func encodeColumns(_ columns: [DatasetColumn]) -> String {
        guard let data = try? ManifestCodec.stableEncoder.encode(columns),
            let text = String(bytes: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    static func encodeDescription(_ description: DatasetDescription) -> String? {
        guard let data = try? ManifestCodec.stableEncoder.encode(description) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
