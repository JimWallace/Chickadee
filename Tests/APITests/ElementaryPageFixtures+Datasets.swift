// Tests/APITests/ElementaryPageFixtures+Datasets.swift
//
// The two Datasets tab pages: the course library list and one dataset.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var datasetPages: [ElementaryPageFixture] {
        [
            instructorDatasetsPage, instructorDatasetPage, assignmentEditPageWithLibrary, courseDataPage,
            submitPageWithData,
        ]
    }

    /// The student Data page: a published dataset with a download, an
    /// unpublished one as staff see it, and the empty course.
    static var courseDataPage: ElementaryPageFixture {
        let published = CourseDataEntry(
            name: "Ward cases", description: "Admissions by ward.", provenance: "Hospital extract",
            licence: "Course use only", isPublished: true, rowsText: "1204 rows",
            columns: [
                DatasetColumn(name: "ward", valueType: .text, description: "Hospital ward"),
                DatasetColumn(name: "systolic", valueType: .integer, unit: "mmHg"),
            ],
            downloads: [
                .init(
                    assignmentTitle: "Lab 2", filename: "cases.csv",
                    href: "/testsetups/setup1/data/cases.csv/mine.csv")
            ])
        let unpublished = CourseDataEntry(
            name: "Draft data", description: nil, provenance: nil, licence: nil, isPublished: false,
            rowsText: "30 rows", columns: [], downloads: [])
        return ElementaryPageFixture(
            typeName: "CourseDataPage",
            archetype: .plainStudentPage,
            renders: [
                CourseDataPage(page: page(currentUser: signedInAdmin), courseCode: "CS135", datasets: []).render(),
                CourseDataPage(
                    page: page(currentUser: signedInAdmin), courseCode: "CS135", datasets: [published, unpublished]
                ).render(),
            ]
        )
    }

    /// The upload page with the student's data line. The exemplar fixture of
    /// this page is in `ElementaryPageFixtures+Student.swift`.
    static var submitPageWithData: ElementaryPageFixture {
        let spec = DatasetSpec(file: "cases.csv", kind: .rowSample, sampleSize: 150)
        return ElementaryPageFixture(
            typeName: "SubmitPage",
            archetype: .plainStudentPage,
            renders: [
                SubmitPage(
                    page: page(currentUser: signedInAdmin), testSetupID: "setup1", assignmentTitle: "Lab 2",
                    acceptAttribute: ".py,.zip", acceptHintText: "Accepts .py or .zip.", errorText: nil,
                    requiredFilesText: nil, chips: SubmitChips(attemptNumber: 1, deadlineText: nil, deadlineISO: nil),
                    githubSubmitURL: nil, aiFeedbackNotice: false,
                    datasets: [SubmitDatasetLink(spec: spec, setupID: "setup1")], dataPageHref: "/data/CS135-F26"
                ).render()
            ]
        )
    }

    /// The edit page's Files panel with the course library: the attach
    /// control, an attached file that pins an older version, and a CSV the
    /// panel offers to move into the library. The exemplar fixture of this
    /// page is in `ElementaryPageFixtures+Editors.swift`.
    static var assignmentEditPageWithLibrary: ElementaryPageFixture {
        var attached = EditorSamples.supportFile(dataset: true, editable: true)
        attached.library = SupportFileLibraryState(
            attachment: .init(sourceText: "VitalDB cases (v1)", newerVersion: 2, isCourseScoped: true))
        var promotable = EditorSamples.supportFile(dataset: false, editable: true)
        promotable.library = SupportFileLibraryState(attachment: nil)
        var edit = EditorSamples.edit(rich: true, embedded: nil)
        edit.supportFileRows = [attached, promotable]
        edit.datasetLibraryOptions = [DatasetLibraryOption(slug: "vitaldb-cases", label: "VitalDB cases (v2)")]
        return ElementaryPageFixture(
            typeName: "AssignmentEditPage",
            archetype: .bodyPartialShim,
            renders: [AssignmentEditPage(page: page(currentUser: signedInAdmin), edit: edit).render()]
        )
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
