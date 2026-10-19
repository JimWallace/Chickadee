// Tests/CoreTests/DatasetPartitionTests.swift
//
// The dealt `partition` kind (docs/datasets-course-library.md §4.11): data row
// `i` is in part `i mod partCount`, the student's part is their deal number
// modulo the count, and a job with no deal number gets the whole file. The
// spec encodes `partCount` only when it is set, so every stored manifest keeps
// its bytes.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetPartitionTests {

    /// Ten data rows, ids 1 to 10.
    private let pool =
        "id,ward\n" + (1...10).map { "\($0),\($0.isMultiple(of: 2) ? "A" : "B")" }.joined(separator: "\n") + "\n"

    private func partition(_ count: Int) -> DatasetSpec {
        DatasetSpec(file: "cases.csv", kind: .partition, partCount: count)
    }

    private func ids(_ csv: String) -> [Int] {
        DatasetMaterializer.normalizedLines(of: csv).lines.dropFirst().compactMap {
            Int($0.prefix(while: { $0 != "," }))
        }
    }

    private func materialized(_ spec: DatasetSpec, deal: Int?) -> String {
        DatasetMaterializer.materialize(source: pool, spec: spec, seedHex: "ab", dealNumber: deal)
    }

    // MARK: - Delivery

    /// The byte pin: three parts of ten rows.
    @Test func eachPartHoldsEveryPartCountthRowInFileOrder() {
        #expect(materialized(partition(3), deal: 0) == "id,ward\n1,B\n4,A\n7,B\n10,A\n")
        #expect(ids(materialized(partition(3), deal: 1)) == [2, 5, 8])
        #expect(ids(materialized(partition(3), deal: 2)) == [3, 6, 9])
    }

    @Test func thePartsAreDisjointAndCoverTheFile() {
        let parts = (0..<4).map { ids(materialized(partition(4), deal: $0)) }
        #expect(parts.flatMap { $0 }.sorted() == Array(1...10))
        #expect(Set(parts.flatMap { $0 }).count == 10)
    }

    /// A deal number past the count wraps, so a second round of students fills
    /// the parts again, and a later change of the count keeps them balanced.
    @Test func theDealNumberWrapsByThePartCount() {
        #expect(materialized(partition(3), deal: 4) == materialized(partition(3), deal: 1))
        #expect(partition(3).part(forDeal: 7) == 1)
        #expect(partition(3).part(forDeal: -1) == nil)
        #expect(DatasetSpec(file: "cases.csv", sampleSize: 3).part(forDeal: 2) == nil)
    }

    /// A job with no student (the class corpus run) has no deal number.
    @Test func noDealNumberGivesTheWholeFile() {
        #expect(materialized(partition(3), deal: nil) == pool)
        #expect(DatasetMaterializer.materialize(source: pool, spec: partition(3), seedHex: "ab") == pool)
    }

    @Test func aHeldBackPartitionKeepsOnlyItsHeader() {
        #expect(DatasetMaterializer.headerOnly(pool) == "id,ward\n")
        #expect(DatasetMaterializer.headerOnly("id,ward\r\n1,A") == "id,ward")
    }

    @Test func lineEndingsAreNormalizedAndTheTrailingNewlineIsMirrored() {
        let crlf = "id,ward\r\n1,A\r\n2,B\r\n3,A"
        #expect(
            DatasetMaterializer.materialize(source: crlf, spec: partition(2), seedHex: "ab", dealNumber: 1)
                == "id,ward\n2,B")
    }

    /// A transform runs on the student's part, after the part is chosen.
    @Test func aTransformRunsOnTheStudentsPart() {
        let spec = DatasetSpec(
            file: "cases.csv", kind: .partition,
            transforms: [DatasetTransform(kind: .missingValues, columns: ["ward"], rate: 1)], partCount: 3)
        #expect(materialized(spec, deal: 1) == "id,ward\n2,\n5,\n8,\n")
    }

    @Test func theResolverPassesTheDealNumberToEveryPartition() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("partition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try pool.write(to: directory.appendingPathComponent("cases.csv"), atomically: true, encoding: .utf8)
        var manifest = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")], language: .python)
        manifest.datasets = [partition(5)]

        let files = try #require(
            DatasetResolver.resolve(
                manifest: manifest, seedHex: "ab", courseSeedHex: nil, dealNumber: 7, sourceDirectory: directory.path))
        #expect(ids(try #require(files["cases.csv"])) == [3, 8])
    }

    // MARK: - The spec

    /// A spec with no part count encodes the bytes it did before partitions
    /// existed: the manifest hash gates the retest fan-out and the runner cache.
    @Test func aSpecWithNoPartCountKeepsItsBytes() throws {
        let plain = try #require(
            String(bytes: try JSONEncoder().encode(DatasetSpec(file: "cases.csv", sampleSize: 3)), encoding: .utf8))
        #expect(!plain.contains("partCount"))
        let decoded = try JSONDecoder().decode(DatasetSpec.self, from: try JSONEncoder().encode(partition(4)))
        #expect(decoded == partition(4))
    }

    @Test func aPartitionIsNotSharedAndOutlivesADetach() {
        #expect(!partition(3).isShared)
        let attached = DatasetSpec(
            file: "cases.csv", kind: .partition, source: DatasetSource(slug: "wards", version: 1), scope: .course,
            partCount: 3)
        #expect(attached.withoutLibraryFields() == partition(3))
        #expect(attached.withScope(.assignment).partCount == 3)
    }

    @Test func onlyAPlainPartitionLetsAJobWithNoStudentGradeTheClass() {
        var manifest = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")], language: .python)
        manifest.datasets = [partition(3)]
        #expect(manifest.variesPerStudent)
        #expect(!manifest.variesBeyondPartitions)
        #expect(manifest.hasPartitionedDatasets)
        manifest.datasets = [
            DatasetSpec(
                file: "cases.csv", kind: .partition,
                transforms: [DatasetTransform(kind: .missingValues, columns: ["ward"], rate: 0.5)], partCount: 3)
        ]
        #expect(manifest.variesBeyondPartitions)
        manifest.datasets = [DatasetSpec(file: "cases.csv", sampleSize: 3)]
        #expect(manifest.variesBeyondPartitions)
        #expect(!manifest.hasPartitionedDatasets)
    }

    // MARK: - Validation

    @Test func aValidPartitionPasses() {
        #expect(DatasetSpecValidation.issue(with: partition(10), sourceCSV: pool) == nil)
    }

    @Test(arguments: [
        (DatasetSpec(file: "cases.csv", kind: .partition, partCount: 1), "2 or more"),
        (DatasetSpec(file: "cases.csv", kind: .partition), "2 or more"),
        (DatasetSpec(file: "cases.csv", kind: .partition, sampleSize: 3, partCount: 2), "no sample size"),
        (DatasetSpec(file: "cases.csv", kind: .partition, stratumColumn: "ward", partCount: 2), "no stratum column"),
        (DatasetSpec(file: "cases.csv", kind: .partition, partCount: 11), "at most 10 parts"),
        (DatasetSpec(file: "cases.csv", sampleSize: 3, partCount: 2), "only applies to a partition"),
        (
            DatasetSpec(
                file: "cases.csv", kind: .partition, source: DatasetSource(slug: "wards", version: 1), scope: .course,
                partCount: 2), "not the same rows"
        ),
    ])
    func anUnusablePartitionIsRefused(spec: DatasetSpec, phrase: String) throws {
        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: pool))
        #expect(issue.contains(phrase), "\(issue)")
    }

    // MARK: - Diagnostics

    /// A class no larger than the part count shares no row.
    @Test func aClassNoLargerThanThePartCountSharesNothing() throws {
        let overlap = try #require(DatasetDiagnostics.overlap(spec: partition(5), sourceCSV: pool, classSize: 5))
        #expect(overlap.rowsPerStudent == 2)
        #expect(overlap.expectedSharedRows == 0)
        #expect(overlap.worstPairSharedRows == 0)
    }

    /// Ten students in five parts: two per part, so 5 of the 45 pairs share
    /// a part, and that pair shares every row.
    @Test func aLargerClassSharesWithinEachPart() throws {
        let overlap = try #require(DatasetDiagnostics.overlap(spec: partition(5), sourceCSV: pool, classSize: 10))
        #expect(abs(overlap.sharedFraction - 5.0 / 45.0) < 1e-9)
        #expect(overlap.worstPairSharedRows == 2)
    }

    @Test func divergenceIsMeasuredPartByPart() {
        let columns = DatasetDiagnostics.divergence(spec: partition(2), sourceCSV: pool, seedCount: 2)
        let ward = columns.first { $0.column == "ward" }
        // Part 0 holds the odd ids (ward B) and part 1 the even ones (ward A),
        // so each part is half the pool's categories away from it.
        #expect(ward.map { abs($0.median - 0.5) < 1e-9 } == true)
    }
}
