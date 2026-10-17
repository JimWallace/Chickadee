// APIServer/Models/APICourseDataset.swift
//
// One dataset in a course's dataset library (docs/datasets-course-library.md).
// The bytes live in its versions (`APICourseDatasetVersion`); this row holds
// what describes the dataset as a whole: its slug, its name, where the data
// came from and under which licence, and whether students can see it.

import Fluent
import Foundation
import Vapor

final class APICourseDataset: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_datasets"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "course_id")
    var courseID: UUID

    /// Unique per course: lowercase letters, digits and hyphens.
    @Field(key: "slug")
    var slug: String

    @Field(key: "name")
    var name: String

    /// What the dataset is, for the student Data page.
    @OptionalField(key: "description")
    var datasetDescription: String?

    /// Where the data came from.
    @OptionalField(key: "provenance")
    var provenance: String?

    /// The licence or the terms of use.
    @OptionalField(key: "licence")
    var licence: String?

    @Field(key: "is_published")
    var isPublished: Bool

    /// The newest version number.
    @Field(key: "current_version")
    var currentVersion: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil, courseID: UUID, slug: String, name: String, datasetDescription: String? = nil,
        provenance: String? = nil, licence: String? = nil, isPublished: Bool = false, currentVersion: Int
    ) {
        self.id = id
        self.courseID = courseID
        self.slug = slug
        self.name = name
        self.datasetDescription = datasetDescription
        self.provenance = provenance
        self.licence = licence
        self.isPublished = isPublished
        self.currentVersion = currentVersion
    }
}
