// Tests/APITests/ElementaryPageFixtures+Datasets.swift
//
// The two Datasets tab pages: the course library list and one dataset.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var datasetPages: [ElementaryPageFixture] {
        [instructorDatasetsPage, instructorDatasetPage]
    }

    static var instructorDatasetsPage: ElementaryPageFixture {
        let rows = [
            InstructorDatasetRow(
                slug: "vitaldb-cases", name: "VitalDB cases", isPublished: true,
                detailsText: "v2 · 1204 rows · 45 KB", usageText: "2 assignments"),
            InstructorDatasetRow(
                slug: "nhanes-bp", name: "NHANES blood pressure", isPublished: false,
                detailsText: "v1 · 300 rows · 9 KB", usageText: "Not attached"),
        ]
        func render(hasCourse: Bool = true, datasets: [InstructorDatasetRow] = [], error: String? = nil) -> String {
            InstructorDatasetsPage(
                page: page(currentUser: signedInAdmin), flash: FlashMessages(error: error),
                hasActiveCourse: hasCourse, courseCode: "CS135", datasets: datasets, maxUploadText: "16.0 MB"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorDatasetsPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false),
                render(),
                render(datasets: rows),
                render(datasets: rows, error: "'cases' is already a dataset slug in this course."),
            ]
        )
    }

    static var instructorDatasetPage: ElementaryPageFixture {
        func detail(published: Bool, governed: Bool, attached: Bool) -> InstructorDatasetDetail {
            InstructorDatasetDetail(
                slug: "vitaldb-cases", name: "VitalDB cases",
                description: governed ? "Surgical cases with vital signs." : nil,
                provenance: governed ? "VitalDB open dataset" : nil, licence: governed ? "CC BY 4.0" : nil,
                isPublished: published, canPublish: governed, currentVersion: 2,
                columns: [
                    DatasetColumn(name: "caseid", valueType: .integer),
                    DatasetColumn(name: "age", valueType: .number, description: "Age at surgery", unit: "years"),
                ],
                versions: [
                    .init(
                        number: 2, detailsText: "cases.csv · 1204 rows · 45 KB", note: "Removed test cases",
                        createdISO: "2026-10-01T12:00:00Z", createdText: "Oct 1, 2026, 8:00 AM",
                        downloadHref: "/instructor/datasets/download?slug=vitaldb-cases&version=2"),
                    .init(
                        number: 1, detailsText: "cases.csv · 1210 rows · 46 KB", note: nil,
                        createdISO: "2026-09-01T12:00:00Z", createdText: "Sep 1, 2026, 8:00 AM",
                        downloadHref: "/instructor/datasets/download?slug=vitaldb-cases&version=1"),
                ],
                usage: attached
                    ? [
                        .init(
                            title: "Assignment 4", editHref: "/instructor/abc123/edit",
                            detailsText: "cases.csv · v1", isBehind: true),
                        .init(title: "Draft setup_x", editHref: nil, detailsText: "cases.csv · v2", isBehind: false),
                    ] : [])
        }
        func render(_ dataset: InstructorDatasetDetail, notice: String? = nil) -> String {
            InstructorDatasetPage(
                page: page(currentUser: signedInAdmin), flash: FlashMessages(success: notice),
                dataset: dataset, maxUploadText: "16.0 MB"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorDatasetPage",
            archetype: .titlebarPage,
            renders: [
                render(detail(published: false, governed: false, attached: false)),
                render(detail(published: false, governed: true, attached: true)),
                render(detail(published: true, governed: true, attached: true)),
                render(detail(published: true, governed: true, attached: false), notice: "Published."),
            ]
        )
    }
}
