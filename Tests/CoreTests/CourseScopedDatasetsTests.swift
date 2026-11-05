// Tests/CoreTests/CourseScopedDatasetsTests.swift
//
// `TestProperties.hasCourseScopedDatasets` decides whether a delivery path
// needs the per-(student, course) seed (docs/datasets-course-library.md).
// Only a library attachment with the course scope counts: the course scope
// without a source, or a source with the assignment scope, does not.

import Foundation
import Testing

@testable import Core

@Suite struct CourseScopedDatasetsTests {

    private let source = DatasetSource(slug: "vitaldb-cases", version: 2)

    @Test func aCourseScopedAttachmentCounts() {
        let props = TestProperties(
            language: nil,
            datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3, source: source, scope: .course)])
        #expect(props.hasCourseScopedDatasets)
    }

    @Test func theCourseScopeWithoutASourceDoesNotCount() {
        let props = TestProperties(
            language: nil,
            datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3, scope: .course)])
        #expect(!props.hasCourseScopedDatasets)
    }

    @Test func anAssignmentScopedAttachmentDoesNotCount() {
        let props = TestProperties(
            language: nil,
            datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3, source: source)])
        #expect(!props.hasCourseScopedDatasets)
    }

    @Test func noDatasetsDoesNotCount() {
        #expect(!TestProperties(language: nil, datasets: []).hasCourseScopedDatasets)
    }
}
