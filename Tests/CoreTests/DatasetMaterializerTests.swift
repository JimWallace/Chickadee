// Tests/CoreTests/DatasetMaterializerTests.swift
//
// Pins the determinism contract for per-student dataset slicing (Phase 1 —
// docs/datasets.md): the server resolves a slice once and ships the bytes to
// the editor + worker + browser, so the SAME (source, spec, seed) must yield
// byte-identical output every time, and the header + chosen-row order must be
// stable.  Also covers DatasetSpec / TestProperties.datasets Codable
// back-compat and the runnerSanitized() strip.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetMaterializerTests {

    private let seedA = String(repeating: "a1b2", count: 16)  // 64 hex chars
    private let seedB = String(repeating: "9f3c", count: 16)

    /// `id`-only CSV with `count` data rows whose single column is the row
    /// index, so the chosen rows are trivially traceable back to their origin.
    private func indexedCSV(count: Int, trailingNewline: Bool = true) -> String {
        var s = "id\n"
        s += (0..<count).map(String.init).joined(separator: "\n")
        if trailingNewline { s += "\n" }
        return s
    }

    private func dataRows(_ csv: String) -> [Int] {
        csv.split(separator: "\n").dropFirst().compactMap { Int($0) }
    }

    @Test func sampleIsDeterministicForSameSeed() {
        let source = indexedCSV(count: 100)
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 10)
        let first = DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA)
        let second = DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA)
        #expect(first == second)
    }

    @Test func differentSeedsGenerallyDiffer() {
        let source = indexedCSV(count: 100)
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 10)
        let a = DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA)
        let b = DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedB)
        #expect(a != b, "Two seeds choosing 10 of 100 rows should select different sets")
    }

    @Test func headerPreservedAndSizeRespected() {
        let source = indexedCSV(count: 100)
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 25)
        let out = DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA)
        #expect(out.hasPrefix("id\n"))
        #expect(dataRows(out).count == 25)
    }

    @Test func chosenRowsKeepOriginalOrderAndAreDistinct() {
        let source = indexedCSV(count: 100)
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 30)
        let rows = dataRows(DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA))
        #expect(rows == rows.sorted(), "Chosen rows keep their original order")
        #expect(Set(rows).count == rows.count, "No duplicate rows")
        #expect(rows.allSatisfy { (0..<100).contains($0) })
    }

    @Test func sampleSizeAtOrAboveRowCountReturnsWholeFile() {
        let source = indexedCSV(count: 10)
        for size in [10, 11, 1000] {
            let spec = DatasetSpec(file: "cases.csv", sampleSize: size)
            #expect(
                DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA) == source)
        }
    }

    @Test func nilSampleSizeReturnsWholeFile() {
        let source = indexedCSV(count: 10)
        let spec = DatasetSpec(file: "cases.csv", sampleSize: nil)
        #expect(DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA) == source)
    }

    @Test func headerOnlyOrEmptyReturnedUnchanged() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5)
        #expect(DatasetMaterializer.materialize(source: "id\n", spec: spec, seedHex: seedA) == "id\n")
        #expect(DatasetMaterializer.materialize(source: "", spec: spec, seedHex: seedA).isEmpty)
    }

    @Test func trailingNewlinePreservedOrAbsentAsInInput() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5)
        let withNL = DatasetMaterializer.materialize(
            source: indexedCSV(count: 20, trailingNewline: true), spec: spec, seedHex: seedA)
        let withoutNL = DatasetMaterializer.materialize(
            source: indexedCSV(count: 20, trailingNewline: false), spec: spec, seedHex: seedA)
        #expect(withNL.hasSuffix("\n"))
        #expect(!withoutNL.hasSuffix("\n"))
        // Same rows chosen either way (newline handling must not perturb selection).
        #expect(dataRows(withNL) == dataRows(withoutNL))
    }

    @Test func crlfLineEndingsNormalizeToLF() {
        let source = "id\r\n" + (0..<20).map(String.init).joined(separator: "\r\n") + "\r\n"
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5)
        let out = DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seedA)
        #expect(!out.contains("\r"))
        #expect(out.hasPrefix("id\n"))
        #expect(dataRows(out).count == 5)
    }
}

@Suite struct DatasetSpecCodableTests {

    @Test func datasetSpecRoundTrips() throws {
        let spec = DatasetSpec(file: "cases.csv", kind: .rowSample, sampleSize: 500)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(DatasetSpec.self, from: data)
        #expect(decoded == spec)
    }

    @Test func datasetSpecDefaultsKindAndSize() throws {
        let json = #"{"file":"cases.csv"}"#
        let decoded = try JSONDecoder().decode(DatasetSpec.self, from: Data(json.utf8))
        #expect(decoded.file == "cases.csv")
        #expect(decoded.kind == .rowSample)
        #expect(decoded.sampleSize == nil)
    }

    @Test func manifestWithoutDatasetsKeyDecodesEmpty() throws {
        // A legacy manifest predates the `datasets` field.
        let json = #"{"schemaVersion":1}"#
        let decoded = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        #expect(decoded.datasets.isEmpty)
    }

    @Test func manifestDatasetsRoundTrip() throws {
        let manifest = TestProperties(datasets: [DatasetSpec(file: "cases.csv", sampleSize: 500)])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.datasets == manifest.datasets)
    }

    @Test func runnerSanitizedStripsDatasets() {
        let manifest = TestProperties(datasets: [DatasetSpec(file: "cases.csv", sampleSize: 500)])
        #expect(manifest.runnerSanitized().datasets.isEmpty)
    }
}
