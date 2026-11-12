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

    /// The JSON-encoded `FHIRDatasetSummary` of a FHIR version; nil for a CSV
    /// version. Read through `summary`.
    @OptionalField(key: "summary_json")
    var summaryJSON: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// The FHIR summary (docs/fhir-datasets-plan.md §5). A stored value that
    /// does not decode reads as nil, rather than failing the read.
    var summary: FHIRDatasetSummary? {
        get {
            summaryJSON.flatMap { try? JSONDecoder().decode(FHIRDatasetSummary.self, from: Data($0.utf8)) }
        }
        set { summaryJSON = newValue.flatMap(Self.encodeSummary) }
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
        rowCount: Int, columns: [DatasetColumn], summary: FHIRDatasetSummary? = nil, note: String? = nil
    ) {
        self.id = id
        self.datasetID = datasetID
        self.version = version
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.rowCount = rowCount
        self.columnsJSON = Self.encodeColumns(columns)
        self.summaryJSON = summary.flatMap(Self.encodeSummary)
        self.note = note
    }

    static func encodeColumns(_ columns: [DatasetColumn]) -> String {
        guard let data = try? ManifestCodec.stableEncoder.encode(columns),
            let text = String(bytes: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    static func encodeSummary(_ summary: FHIRDatasetSummary) -> String? {
        guard let data = try? ManifestCodec.stableEncoder.encode(summary) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
