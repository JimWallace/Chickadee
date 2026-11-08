// APIServer/Services/APIUserSessionLookup.swift
//
// Loads the signed-in user for the session authenticator, which runs on every
// request that carries a session cookie (#2905).
//
// Fluent's `find` builds the query through `QueryBuilder` and reflects over the
// model's properties several times on the way; a profile of the release server
// measured about 0.9 ms of CPU for the 20-column `APIUser`, against about
// 0.45 ms for the same row read through SQLKit and decoded into the model.

import Fluent
import FluentSQL
import Foundation
import SQLKit

enum APIUserSessionLookup {
    /// The user with this ID, or nil when there is none.
    ///
    /// The row is decoded with FluentSQL's `decode(fluentModel:)`, which runs
    /// the model's own `output(from:)`, the path Fluent's `find` uses. So the
    /// user has the same fetched state: `$id.exists` is true, no field is an
    /// unsaved change, and a later `save()` (the avatar and account routes save
    /// the signed-in user) writes only the fields it changes. A database
    /// without SQL uses Fluent's `find`.
    static func find(_ id: UUID, on db: any Database) async throws -> APIUser? {
        guard let sql = db as? (any SQLDatabase) else {
            return try await APIUser.find(id, on: db)
        }
        return try await sql.select()
            .column("*")
            .from(APIUser.schema)
            .where("id", .equal, id)
            .limit(1)
            .first(decodingFluent: APIUser.self)
    }
}
