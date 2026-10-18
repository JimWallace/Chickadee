// APIServer/Routes/Web/InstructorDatasetDetail.swift
//
// One dataset as its own page shows it (`InstructorDatasetPage`), made from
// the library rows. Every string is formatted here, so the view only lays it
// out.

import Core
import Foundation

/// One dataset on its own page.
struct InstructorDatasetDetail: Sendable {
    /// One uploaded version.
    struct Version: Sendable {
        let number: Int
        /// "cases.csv · 1204 rows · 45 KB"
        let detailsText: String
        let note: String?
        /// ISO 8601, for the relative time; empty when unknown.
        let createdISO: String
        /// The absolute time, shown before the script runs; "—" when unknown.
        let createdText: String
        let downloadHref: String
    }

    /// One assignment or draft that attaches the dataset.
    struct Usage: Sendable {
        let title: String
        /// The assignment editor; nil for a draft.
        let editHref: String?
        /// "cases.csv · v2"
        let detailsText: String
        /// The pinned version is older than the newest.
        let isBehind: Bool
    }

    let slug: String
    let name: String
    let description: String?
    let provenance: String?
    let licence: String?
    let isPublished: Bool
    /// Publishing needs a provenance and a licence.
    let canPublish: Bool
    let currentVersion: Int
    /// The newest version's dictionary.
    let columns: [DatasetColumn]
    /// Newest first.
    let versions: [Version]
    let usage: [Usage]

    var downloadHref: String {
        "/instructor/datasets/download?slug=\(urlEncode(slug))&version=\(currentVersion)"
    }

    static func href(slug: String) -> String {
        "/instructor/datasets/view?slug=\(urlEncode(slug))"
    }

    static func rowsText(_ count: Int) -> String {
        count == 1 ? "1 row" : "\(count) rows"
    }

    static func usageText(count: Int) -> String {
        switch count {
        case 0: "Not attached"
        case 1: "1 assignment"
        default: "\(count) assignments"
        }
    }
}

extension InstructorDatasetDetail {
    init(dataset: APICourseDataset, versions: [APICourseDatasetVersion], usage: [CourseDatasetService.Usage]) {
        let formatter = waterlooDateTimeFormatter()
        let slug = dataset.slug
        let current = dataset.currentVersion
        self.init(
            slug: slug, name: dataset.name, description: dataset.datasetDescription,
            provenance: dataset.provenance, licence: dataset.licence, isPublished: dataset.isPublished,
            canPublish: CourseDatasetService.hasGovernance(dataset), currentVersion: current,
            columns: versions.first { $0.version == current }?.columns ?? [],
            versions: versions.reversed().map { version in
                Version(
                    number: version.version,
                    detailsText: [
                        version.filename, Self.rowsText(version.rowCount), formatBytes(version.sizeBytes),
                    ].joined(separator: " · "),
                    note: version.note, createdISO: version.createdAt.map(iso8601String) ?? "",
                    createdText: version.createdAt.map(formatter.string(from:)) ?? "—",
                    downloadHref: "/instructor/datasets/download?slug=\(urlEncode(slug))&version=\(version.version)")
            },
            usage: usage.map { entry in
                Usage(
                    title: entry.assignmentTitle ?? "Draft \(entry.testSetupID)",
                    editHref: entry.assignmentPublicID.map { "/instructor/\($0)/edit" },
                    detailsText: "\(entry.file) · v\(entry.version)", isBehind: entry.version < current)
            })
    }
}
