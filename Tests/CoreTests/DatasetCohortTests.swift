// Tests/CoreTests/DatasetCohortTests.swift
//
// The course cohort (docs/datasets-course-library.md, D4 and D6): the seed
// derivation is pure and pinned, two library datasets give one student two
// different seeds, the resolver slices each spec with its own seed, and the
// row picks have the two properties the cohort arc depends on.
//
// - Nested samples. A smaller sample from the same seed is a subset of a
//   larger one, so a lab that gives 100 rows and a later lab that gives 500
//   give the same first 100 patients.
// - Version stability. The picks depend on the seed and the row count only,
//   so a new version that keeps the row count keeps every student's rows, and
//   one that changes it deals the cohort again.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetCohortTests {

    private let assignmentSeed = String(repeating: "a1b2", count: 16)
    private let courseSeed = String(repeating: "c3d4", count: 16)

    private func pool(rows: Int, value: (Int) -> String = { "v\($0)" }) -> String {
        "id,value\n" + (0..<rows).map { "\($0),\(value($0))" }.joined(separator: "\n") + "\n"
    }

    /// The `id` column of a materialized slice.
    private func ids(_ csv: String) -> Set<String> {
        Set(csv.split(separator: "\n").dropFirst().map { String($0.split(separator: ",")[0]) })
    }

    private func courseSpec(slug: String, sampleSize: Int) -> DatasetSpec {
        DatasetSpec(
            file: "cases.csv", sampleSize: sampleSize,
            source: DatasetSource(slug: slug, version: 1), scope: .course)
    }

    // MARK: - Derivation

    /// Pinned to a literal: the derived seed is the student's rows, so a change
    /// to the fold must fail here rather than re-deal every cohort.
    @Test func theCourseScopedSeedIsPinned() {
        #expect(
            DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: "vitaldb-cases")
                == "5ece12fe3ddb765b977b12408b7793a7afd960f60c36a10c3270bbf40514c0b2")
    }

    @Test func theCourseScopedSeedHasTheShapeOfAnAssignmentSeed() {
        let seed = DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: "vitaldb-cases")
        #expect(seed.count == 64)
        #expect(seed.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func twoSlugsOnOneCourseSeedGiveTwoSeeds() {
        #expect(
            DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: "vitaldb-cases")
                != DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: "nhanes-bp"))
    }

    @Test func anAssignmentScopeUsesTheAssignmentSeed() {
        let spec = DatasetSpec(
            file: "cases.csv", sampleSize: 5, source: DatasetSource(slug: "vitaldb-cases", version: 1))
        #expect(
            DatasetSeedDerivation.effectiveSeed(
                spec: spec, assignmentSeedHex: assignmentSeed, courseSeedHex: courseSeed) == assignmentSeed)
    }

    @Test func aCourseScopeWithoutACourseSeedUsesTheAssignmentSeed() {
        #expect(
            DatasetSeedDerivation.effectiveSeed(
                spec: courseSpec(slug: "vitaldb-cases", sampleSize: 5), assignmentSeedHex: assignmentSeed,
                courseSeedHex: nil) == assignmentSeed)
    }

    @Test func aCourseScopeUsesTheDerivedSeed() {
        #expect(
            DatasetSeedDerivation.effectiveSeed(
                spec: courseSpec(slug: "vitaldb-cases", sampleSize: 5), assignmentSeedHex: assignmentSeed,
                courseSeedHex: courseSeed)
                == DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: "vitaldb-cases"))
    }

    // MARK: - Resolver

    private func withPool(_ csv: String, _ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-cohort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try csv.write(toFile: dir.path + "/cases.csv", atomically: true, encoding: .utf8)
        try body(dir.path)
    }

    /// Two assignments with different assignment seeds give one student the
    /// same rows of a course-scoped dataset.
    @Test func aCourseScopedSpecGivesTheSameRowsUnderEveryAssignmentSeed() throws {
        try withPool(pool(rows: 200)) { dir in
            let manifest = TestProperties(language: nil, datasets: [courseSpec(slug: "vitaldb-cases", sampleSize: 20)])
            let lab = try #require(
                DatasetResolver.resolve(
                    manifest: manifest, seedHex: assignmentSeed, courseSeedHex: courseSeed, sourceDirectory: dir))
            let report = try #require(
                DatasetResolver.resolve(
                    manifest: manifest, seedHex: String(repeating: "e5f6", count: 16), courseSeedHex: courseSeed,
                    sourceDirectory: dir))
            #expect(lab["cases.csv"] == report["cases.csv"])
        }
    }

    @Test func theOldResolverSignatureSlicesWithTheAssignmentSeed() throws {
        try withPool(pool(rows: 200)) { dir in
            let manifest = TestProperties(language: nil, datasets: [courseSpec(slug: "vitaldb-cases", sampleSize: 20)])
            let viaOld = DatasetResolver.resolve(manifest: manifest, seedHex: assignmentSeed, sourceDirectory: dir)
            let viaNew = DatasetResolver.resolve(
                manifest: manifest, seedHex: assignmentSeed, courseSeedHex: nil, sourceDirectory: dir)
            #expect(viaOld == viaNew)
            let assignmentScoped = DatasetSpec(file: "cases.csv", sampleSize: 20)
            #expect(
                viaOld?["cases.csv"]
                    == DatasetMaterializer.materialize(
                        source: pool(rows: 200), spec: assignmentScoped, seedHex: assignmentSeed))
        }
    }

    // MARK: - Pick properties

    @Test(arguments: [(10, 50), (100, 500), (1, 199)])
    func aSmallerSampleIsASubsetOfALargerOne(small: Int, large: Int) {
        let source = pool(rows: 1000)
        let seed = DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: "vitaldb-cases")
        let few = DatasetMaterializer.materialize(
            source: source, spec: DatasetSpec(file: "cases.csv", sampleSize: small), seedHex: seed)
        let many = DatasetMaterializer.materialize(
            source: source, spec: DatasetSpec(file: "cases.csv", sampleSize: large), seedHex: seed)
        #expect(ids(few).count == small)
        #expect(ids(few).isSubset(of: ids(many)))
    }

    @Test func aVersionThatKeepsTheRowCountKeepsTheRows() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 30)
        let before = DatasetMaterializer.materialize(source: pool(rows: 300), spec: spec, seedHex: assignmentSeed)
        let corrected = DatasetMaterializer.materialize(
            source: pool(rows: 300) { "corrected\($0)" }, spec: spec, seedHex: assignmentSeed)
        #expect(ids(before) == ids(corrected))
        #expect(before != corrected)
    }

    @Test func aVersionThatChangesTheRowCountDealsAgain() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 30)
        let before = DatasetMaterializer.materialize(source: pool(rows: 300), spec: spec, seedHex: assignmentSeed)
        let grown = DatasetMaterializer.materialize(source: pool(rows: 301), spec: spec, seedHex: assignmentSeed)
        #expect(ids(before) != ids(grown))
    }
}
