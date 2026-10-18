// APIServer/Models/APICourseGroupSet.swift
//
// A set of student groups in one course, for example "Lab sections"
// (docs/lab-groups.md). A student is in at most one group of a set. The set
// records its source, so a synced set stays read-only in the UI. Rows follow
// their course on delete.

import Fluent
import Vapor

final class APICourseGroupSet: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "course_group_sets"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "course_id")
    var courseID: UUID

    @Field(key: "name")
    var name: String

    /// A `CourseGroupSource` raw value. Read it through `source`.
    @Field(key: "source")
    var sourceRaw: String

    /// The D2L group category or section list a synced set reads. Nil for a
    /// manual set.
    @OptionalField(key: "external_id")
    var externalID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// When the sweep last replaced this set's memberships. Nil for a manual
    /// set, and for a synced set the sweep has not reached yet.
    @OptionalField(key: "last_synced_at")
    var lastSyncedAt: Date?

    init() {}

    init(id: UUID? = nil, courseID: UUID, name: String, source: CourseGroupSource, externalID: String? = nil) {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.sourceRaw = source.rawValue
        self.externalID = externalID
    }
}

extension APICourseGroupSet {
    /// The set's source, or nil for a value this build does not know.
    var source: CourseGroupSource? { CourseGroupSource(rawValue: sourceRaw) }

    /// True when Chickadee owns this set's groups. A source this build does
    /// not know reads as synced, so an unknown set is never edited by hand.
    var acceptsManualEdits: Bool { source == .manual }
}
