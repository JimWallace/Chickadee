// Core/Models/DatasetSource.swift
//
// Where an attached dataset's bytes came from (docs/datasets-course-library.md,
// D3). A spec with a source was attached from the course dataset library: its
// file in the setup zip is a copy of one pinned library version.
//
// The reference is by slug and version, not by database ID. A slug is unique
// per course and survives a course clone and a bundle import unchanged, so a
// copied assignment resolves its source in the new course with no ID map.

/// The library dataset and version an attached file was copied from.
public struct DatasetSource: Codable, Sendable, Equatable {
    /// The dataset's per-course slug.
    public let slug: String
    /// The pinned version number. Versions start at 1.
    public let version: Int

    public init(slug: String, version: Int) {
        self.slug = slug
        self.version = version
    }
}
