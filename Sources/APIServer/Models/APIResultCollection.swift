// APIServer/Models/APIResultCollection.swift
//
// Side table carrying the serialized TestOutcomeCollection blob for each
// result row (#1173). The blob is by far the widest thing that ever lived on
// `results` (up to the 6 MB collection budget per row), and most queries —
// grade folds, list pages, sweeps, the preferred-result maps — never want
// it. Moving it here makes every full-row `APIResult` load blob-free by
// construction; the handful of readers that genuinely need the collection
// fetch it explicitly via `loadCollectionJSON(on:)` / `collectionJSONByResultID`.

import Fluent
import Vapor

final class APIResultCollection: Model, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "result_collections"

    /// Same value as the owning `results.id` — one blob per result.
    @ID(custom: "result_id", generatedBy: .user)
    var id: String?

    @Field(key: "collection_json")
    var collectionJSON: String  // serialised TestOutcomeCollection

    init() {}

    init(resultID: String, collectionJSON: String) {
        self.id = resultID
        self.collectionJSON = collectionJSON
    }
}

extension APIResult {
    /// The ONE write path for a new result: stamps the denormalized grade
    /// columns from the collection, then persists the result row and its
    /// blob side-table row together in a transaction (composes with an
    /// enclosing transaction — the Fluent drivers no-op a nested `BEGIN`).
    func saveWithCollection(json: String, on db: Database) async throws {
        stampGradeFields(from: json)
        try await db.transaction { tx in
            try await self.save(on: tx)
            try await APIResultCollection(resultID: try self.requireID(), collectionJSON: json)
                .save(on: tx)
        }
    }

    /// This result's collection blob, or nil when the side-table row is
    /// missing (should not happen for rows written after #1173 — the write
    /// path is transactional and deletes cascade from `results`).
    func loadCollectionJSON(on db: Database) async throws -> String? {
        guard let id else { return nil }
        return try await APIResultCollection.find(id, on: db)?.collectionJSON
    }
}

/// Batch blob fetch, keyed by result ID. Chunked to stay under
/// bind-parameter limits, like the loaders in BestGradePercentBySubmissionID.
func collectionJSONByResultID(
    for resultIDs: some Collection<String>,
    on db: Database
) async throws -> [String: String] {
    guard !resultIDs.isEmpty else { return [:] }
    let chunkSize = 5_000
    let ids = Array(resultIDs)
    var byID: [String: String] = [:]
    var index = ids.startIndex
    while index < ids.endIndex {
        let end =
            ids.index(index, offsetBy: chunkSize, limitedBy: ids.endIndex)
            ?? ids.endIndex
        let page = try await APIResultCollection.query(on: db)
            .filter(\.$id ~~ Array(ids[index..<end]))
            .all()
        for row in page {
            if let id = row.id { byID[id] = row.collectionJSON }
        }
        index = end
    }
    return byID
}
