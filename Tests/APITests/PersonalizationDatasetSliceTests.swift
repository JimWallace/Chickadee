// Tests/APITests/PersonalizationDatasetSliceTests.swift
//
// Pins the seam between the two per-student systems: an expression that reads a
// per-student dataset must see THE STUDENT'S SLICE, not the instructor's pool.
//
// Before this, `PersonalizationEvaluator` spawned with its cwd set to the shared
// support directory — which holds the full pool — so an `expectedVarRef`
// expression over a sampled dataset resolved the pool's answer and delivered it
// to every student as their own expected value.  Structural notebook checks did
// not notice; any value-based check was wrong for the entire class, silently.
//
// Runs a real `python3` subprocess, like the other evaluator suites.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct PersonalizationDatasetSliceTests {

    private let seed = String(repeating: "a1b2", count: 16)

    /// A pool of `n` data rows under one `id` column.
    private func indexedCSV(_ n: Int) -> String {
        "id\n" + (0..<n).map(String.init).joined(separator: "\n") + "\n"
    }

    private func withSupportDir(_ body: (String) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-slice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir.path)
    }

    /// Counts the data rows the expression actually saw.
    private let countRows = PersonalizationExpression(
        name: "rows", expression: "sum(1 for line in open('cases.csv') if line.strip()) - 1")

    // MARK: - The defect this closes

    @Test func expressionSeesTheStudentsSliceRatherThanThePool() async throws {
        try await withSupportDir { dir in
            try indexedCSV(100).write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(
                globalExpressions: [countRows],
                datasets: [DatasetSpec(file: "cases.csv", sampleSize: 10)])

            let resolution = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seed, supportFilesDirectory: dir, language: .python)

            #expect(resolution.evaluationError == nil)
            // 10, not 100: the pool has 100 rows and would be the old answer.
            #expect(resolution.substitutions["rows"] == "10")
        }
    }

    @Test func expressionAgreesWithTheBytesTheStudentIsDelivered() async throws {
        try await withSupportDir { dir in
            let pool = indexedCSV(60)
            try pool.write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let spec = DatasetSpec(file: "cases.csv", sampleSize: 7)
            let manifest = TestProperties(
                globalExpressions: [
                    PersonalizationExpression(
                        name: "first",
                        expression: "int(open('cases.csv').read().splitlines()[1])")
                ],
                datasets: [spec])

            let resolution = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seed, supportFilesDirectory: dir, language: .python)

            // The delivered slice is what DatasetResolver hands the worker and
            // the editor; the expression must agree with it, not merely differ
            // from the pool.
            let delivered = DatasetMaterializer.materialize(
                source: pool, spec: spec, seedHex: seed)
            let firstDataRow = try #require(delivered.split(separator: "\n").dropFirst().first)
            #expect(resolution.substitutions["first"] == String(firstDataRow))
        }
    }

    @Test func sharedPoolIsNeverRewrittenForOneStudent() async throws {
        try await withSupportDir { dir in
            let pool = indexedCSV(40)
            try pool.write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(
                globalExpressions: [countRows],
                datasets: [DatasetSpec(file: "cases.csv", sampleSize: 5)])

            _ = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seed, supportFilesDirectory: dir, language: .python)

            // Every student's evaluation reads this directory. Materializing
            // into it would hand the next student the previous one's slice.
            let onDisk = try String(contentsOfFile: dir + "/cases.csv", encoding: .utf8)
            #expect(onDisk == pool)
        }
    }

    @Test func differentStudentsGetDifferentAnswers() async throws {
        try await withSupportDir { dir in
            try indexedCSV(200).write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(
                globalExpressions: [
                    PersonalizationExpression(
                        name: "total",
                        expression:
                            "sum(int(x) for x in open('cases.csv').read().split()[1:])")
                ],
                datasets: [DatasetSpec(file: "cases.csv", sampleSize: 20)])

            let a = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: String(repeating: "1234", count: 16),
                supportFilesDirectory: dir, language: .python)
            let b = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: String(repeating: "cdef", count: 16),
                supportFilesDirectory: dir, language: .python)

            #expect(a.substitutions["total"] != nil)
            #expect(a.substitutions["total"] != b.substitutions["total"])
        }
    }

    // MARK: - Everything that is not a dataset is untouched

    @Test func nonDatasetAssignmentStillReadsSupportFilesDirectly() async throws {
        try await withSupportDir { dir in
            try "hello".write(toFile: dir + "/quotes.txt", atomically: true, encoding: .utf8)
            let manifest = TestProperties(
                globalExpressions: [
                    PersonalizationExpression(
                        name: "text", expression: "open('quotes.txt').read()")
                ])

            let resolution = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seed, supportFilesDirectory: dir, language: .python)

            #expect(resolution.substitutions["text"] == "'hello'")
        }
    }

    @Test func supportFilesBesideADatasetStillResolve() async throws {
        try await withSupportDir { dir in
            try indexedCSV(30).write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            try "ward-3B".write(toFile: dir + "/notes.txt", atomically: true, encoding: .utf8)
            let manifest = TestProperties(
                globalExpressions: [
                    PersonalizationExpression(
                        name: "note", expression: "open('notes.txt').read()"),
                    countRows,
                ],
                datasets: [DatasetSpec(file: "cases.csv", sampleSize: 4)])

            let resolution = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seed, supportFilesDirectory: dir, language: .python)

            // The overlay replaces the dataset and symlinks the rest, so a
            // helper beside it must still be readable.
            #expect(resolution.substitutions["note"] == "'ward-3B'")
            #expect(resolution.substitutions["rows"] == "4")
        }
    }

    @Test func pythonHelperModulesStillImportThroughTheOverlay() async throws {
        try await withSupportDir { dir in
            try indexedCSV(30).write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            try "def bump(n):\n    return n + 1\n"
                .write(toFile: dir + "/helpers.py", atomically: true, encoding: .utf8)
            let manifest = TestProperties(
                globalExpressions: [
                    PersonalizationExpression(name: "bumped", expression: "helpers.bump(41)")
                ],
                datasets: [DatasetSpec(file: "cases.csv", sampleSize: 4)])

            let resolution = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seed, supportFilesDirectory: dir, language: .python)

            // The auto-loaded helper resolves via the language's path variable,
            // which must follow the overlay rather than stay on the pool.
            #expect(resolution.evaluationError == nil)
            #expect(resolution.substitutions["bumped"] == "42")
        }
    }
}
