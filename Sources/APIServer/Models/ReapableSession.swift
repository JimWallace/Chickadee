// APIServer/Models/ReapableSession.swift
//
// The reaper's view of Vapor's `_fluent_sessions` table. The table is
// Fluent's own; this model maps the two columns `SessionReaperService` reads.

import Fluent
import Foundation

/// Minimal Fluent view of Vapor's `_fluent_sessions` table, used only by the
/// reaper so it can age rows out with the same typed `created_at < cutoff`
/// query the other reapers use.  It deliberately maps only `id` and the
/// `created_at` column added by `AddSessionsCreatedAt`; the `key`/`data`
/// columns are owned and written by Fluent's `SessionRecord`.  No migration is
/// attached — the table already exists.
///
/// `@unchecked Sendable` for the same reason as every Fluent model here:
/// `Model` requires reference semantics with mutable stored properties, and
/// Fluent's own `SessionRecord` is declared the same way.
final class ReapableSession: Model, @unchecked Sendable {
    static let schema = "_fluent_sessions"

    @ID(key: .id) var id: UUID?

    /// Nullable: pre-`AddSessionsCreatedAt` rows have NULL here and are left
    /// untouched by the reaper (NULL never satisfies `< cutoff`).
    @OptionalField(key: "created_at") var createdAt: Date?

    init() {}
}
