// APIServer/Routes/Web/SupportFileLibraryState.swift
//
// What the edit page's Files panel shows about the course dataset library
// (docs/datasets-course-library.md §4.5, slice 5b): for each support file,
// whether it is attached and to which version, and for the attach control,
// the course's datasets.

import Core
import Fluent
import Foundation

/// One support file's place in the course library.
struct SupportFileLibraryState: Encodable, Sendable {
    /// What an attached file shows. Nil for a file that is not attached, which
    /// the panel offers to move into the library.
    struct Attachment: Encodable, Sendable {
        /// "VitalDB cases (v2)"
        let sourceText: String
        /// The newest version, when the file pins an older one.
        let newerVersion: Int?
        let isCourseScoped: Bool
    }

    let attachment: Attachment?
}

/// One dataset in the attach control.
struct DatasetLibraryOption: Encodable, Sendable {
    let slug: String
    /// "VitalDB cases (v2)"
    let label: String
}

/// `rows` with each support file's library state, and the course's datasets
/// for the attach control. A file that is not attached gets a state only when
/// it is a CSV, the one format the library holds, and not a grader-only file,
/// which a promote refuses.
func withLibraryStates(
    _ rows: [EditableSuiteRow], setup: APITestSetup, on db: any Database
) async throws -> (rows: [EditableSuiteRow], options: [DatasetLibraryOption]) {
    let datasets = try await CourseDatasetService.list(courseID: setup.courseID, on: db)
    let bySlug = Dictionary(datasets.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    let manifest = setup.decodedManifest()
    let graderOnly = manifest?.graderOnlyFileSet ?? []
    let states = rows.map { row -> EditableSuiteRow in
        var row = row
        if let spec = manifest?.libraryAttachment(for: row.name), let source = spec.source {
            let dataset = bySlug[source.slug]
            let behind = dataset.map { CourseDatasetService.attachmentIsBehind(spec, dataset: $0) } ?? false
            row.library = SupportFileLibraryState(
                attachment: .init(
                    sourceText: "\(dataset?.name ?? source.slug) (v\(source.version))",
                    newerVersion: behind ? dataset?.currentVersion : nil,
                    isCourseScoped: spec.scope == .course))
        } else if row.name.lowercased().hasSuffix(".csv"), !graderOnly.contains(row.name) {
            row.library = SupportFileLibraryState(attachment: nil)
        }
        return row
    }
    let options = datasets.map { DatasetLibraryOption(slug: $0.slug, label: "\($0.name) (v\($0.currentVersion))") }
    return (states, options)
}
