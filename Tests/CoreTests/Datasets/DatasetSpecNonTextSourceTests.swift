// Tests/CoreTests/Datasets/DatasetSpecNonTextSourceTests.swift
//
// Branches of `DatasetSpecValidation` that the coverage report showed as never
// run: a transform or a partition on a file whose bytes are not UTF-8 text (the
// caller passes `sourceCSV: nil`), and a door other than the library attach
// path that tries to change a dataset's slice scope.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetSpecNonTextSourceTests {

    @Test func aTransformOnANonTextFileIsRefused() throws {
        let spec = DatasetSpec(
            file: "vitals.csv",
            transforms: [DatasetTransform(kind: .missingValues, columns: ["pulse"], rate: 0.1)])

        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: nil))
        #expect(issue.contains("'vitals.csv' is not UTF-8 text"))
        #expect(issue.contains("no columns to transform"))
    }

    @Test func aPartitionOfANonTextFileIsRefused() throws {
        let spec = DatasetSpec(file: "vitals.csv", kind: .partition, partCount: 2)

        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: nil))
        #expect(issue.contains("'vitals.csv' is not UTF-8 text"))
        #expect(issue.contains("no rows to split"))
    }

    @Test func thePartitionPassesOnceTheFileIsText() {
        let spec = DatasetSpec(file: "vitals.csv", kind: .partition, partCount: 2)
        let csv = "id,pulse\n1,70\n2,80\n3,90\n"

        #expect(DatasetSpecValidation.issue(with: spec, sourceCSV: csv) == nil)
    }

    @Test func aNonLibraryDoorCannotChangeTheScope() throws {
        let proposed = DatasetSpec(file: "vitals.csv", scope: .course)

        let issue = try #require(DatasetSpecValidation.libraryFieldIssue(proposed: proposed, stored: nil))
        #expect(issue.contains("same rows in every assignment"))
        #expect(issue.contains("cannot be changed here"))
    }

    @Test func theDefaultScopeMatchesAMissingStoredSpec() {
        let proposed = DatasetSpec(file: "vitals.csv")

        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: proposed, stored: nil) == nil)
    }
}
