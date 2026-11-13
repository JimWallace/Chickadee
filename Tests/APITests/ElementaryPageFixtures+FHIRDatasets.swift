// Tests/APITests/ElementaryPageFixtures+FHIRDatasets.swift
//
// The dataset pages with a FHIR NDJSON dataset (docs/fhir-datasets-plan.md
// §5): the Datasets tab page with its FHIR dictionary and example pick, the
// student Data page with the summary, and the upload page's data line. The
// CSV fixtures of the same pages are in `ElementaryPageFixtures+Datasets.swift`.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var fhirDatasetPages: [ElementaryPageFixture] {
        [instructorFHIRDatasetPage, courseFHIRDataPage, submitPageWithFHIRData]
    }

    /// A FHIR summary with prose on one type and one code, a code with no
    /// system, an omitted code and a dangling reference.
    static var fhirSummarySample: FHIRDatasetSummary {
        FHIRDatasetSummary(
            fhirVersion: FHIRDatasetSummary.readAsVersion, resourceCount: 5, patientCount: 2,
            resourceTypes: [
                .init(resourceType: "Observation", count: 3, description: "Vital signs taken at triage"),
                .init(resourceType: "Patient", count: 2),
            ],
            codes: [
                .init(
                    resourceType: "Observation", system: "http://loinc.org", code: "8310-5",
                    display: "Body temperature", count: 2, units: ["Cel"], description: "Oral, at triage"),
                .init(
                    resourceType: "Observation", system: nil, code: "local-1", display: nil, count: 1, units: []),
            ],
            omittedCodeCount: 1, danglingPatientReferences: 1,
            example: .init(
                resourceType: "Observation", id: "o1",
                json: #"{"resourceType":"Observation","id":"o1","status":"final","subject":{"reference":"Patient/p1"}}"#
            ))
    }

    static var instructorFHIRDatasetPage: ElementaryPageFixture {
        func detail(summary: FHIRDatasetSummary) -> InstructorDatasetDetail {
            InstructorDatasetDetail(
                slug: "ed-feed", name: "ED feed", description: "A simulated emergency department feed.",
                provenance: "Generated for the course", licence: "CC0", isPublished: true, canPublish: true,
                currentVersion: 1, columns: [],
                versions: [
                    .init(
                        number: 1, detailsText: "ed_feed.ndjson · 2 patients · 1 KB", note: nil,
                        createdISO: "2026-11-01T12:00:00Z", createdText: "Nov 1, 2026, 7:00 AM",
                        downloadHref: "/instructor/datasets/download?slug=ed-feed&version=1")
                ],
                usage: [], format: .fhirNdjson, fhir: summary)
        }
        var bare = fhirSummarySample
        bare.example = nil
        func render(_ dataset: InstructorDatasetDetail) -> String {
            InstructorDatasetPage(
                page: page(currentUser: signedInAdmin), dataset: dataset, maxUploadText: "16.0 MB"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorDatasetPage",
            archetype: .titlebarPage,
            renders: [render(detail(summary: fhirSummarySample)), render(detail(summary: bare))]
        )
    }

    static var courseFHIRDataPage: ElementaryPageFixture {
        let entry = CourseDataEntry(
            name: "ED feed", description: "A simulated emergency department feed.",
            provenance: "Generated for the course", licence: "CC0", isPublished: true, rowsText: "2 patients",
            columns: [],
            downloads: [
                .init(
                    assignmentTitle: "Assignment 3", filename: "ed_feed.ndjson",
                    href: "/testsetups/setup1/data/ed_feed.ndjson/mine.ndjson")
            ], fhir: fhirSummarySample)
        return ElementaryPageFixture(
            typeName: "CourseDataPage",
            archetype: .plainStudentPage,
            renders: [
                CourseDataPage(page: page(currentUser: signedInAdmin), courseCode: "HLTH230", datasets: [entry])
                    .render()
            ]
        )
    }

    static var submitPageWithFHIRData: ElementaryPageFixture {
        let spec = DatasetSpec(file: "ed_feed.ndjson", kind: .rowSample, format: .fhirNdjson)
        return ElementaryPageFixture(
            typeName: "SubmitPage",
            archetype: .plainStudentPage,
            renders: [
                SubmitPage(
                    page: page(currentUser: signedInAdmin), testSetupID: "setup1", assignmentTitle: "Assignment 3",
                    acceptAttribute: ".py,.zip", acceptHintText: "Accepts .py or .zip.", errorText: nil,
                    requiredFilesText: nil, chips: SubmitChips(attemptNumber: 1, deadlineText: nil, deadlineISO: nil),
                    githubSubmitURL: nil, aiFeedbackNotice: false,
                    datasets: [SubmitDatasetLink(spec: spec, setupID: "setup1")], dataPageHref: "/data/HLTH230-W27"
                ).render()
            ]
        )
    }
}
