// Tests/CoreTests/DatasetStratifiedSamplingTests.swift
//
// `DatasetKind.stratifiedSample` (Phase 1.5 of docs/datasets.md): the same
// per-student slice as `rowSample`, apportioned across the distinct values of
// one column so every category in the pool survives into every student's copy.
//
// What is worth asserting here is what a plain row sample cannot promise —
// every category present, sizes roughly proportional, the budget spent exactly
// — plus the two properties the whole feature rests on: the output is a pure
// function of (source, spec, seed), and the envelope (header, row order, line
// endings) is identical to `rowSample`'s, since both kinds are delivered to the
// same `pd.read_csv` line.
//
// Apportionment is tested directly rather than inferred from a slice: the
// selection around it is seeded, so a table of expected splits is both easier
// to read and stricter than counting rows in a CSV.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetStratifiedSamplingTests {

    private let seedA = String(repeating: "a1b2", count: 16)
    private let seedB = String(repeating: "9f3c", count: 16)

    /// A pool whose `ward` column is deliberately lopsided: 60 rows in `3A`,
    /// 30 in `3B`, 9 in `4C` and a single `ICU` row — the rare category a plain
    /// row sample drops most of the time.
    private func lopsidedPool() -> String {
        var rows: [String] = ["id,ward,score"]
        var id = 0
        func add(_ ward: String, _ count: Int) {
            for _ in 0..<count {
                rows.append("\(id),\(ward),\(id % 7)")
                id += 1
            }
        }
        add("3A", 60)
        add("3B", 30)
        add("4C", 9)
        add("ICU", 1)
        return rows.joined(separator: "\n") + "\n"
    }

    private func wards(_ csv: String) -> [String] {
        csv.split(separator: "\n").dropFirst().map { line in
            String(DatasetMaterializer.splitCSVLine(line)[1])
        }
    }

    private func spec(size: Int?, column: String? = "ward") -> DatasetSpec {
        DatasetSpec(file: "cases.csv", kind: .stratifiedSample, sampleSize: size, stratumColumn: column)
    }

    // MARK: - The promise the kind exists to make

    @Test func everyCategorySurvivesEvenTheSingletonOne() {
        let pool = lopsidedPool()
        // Ten different students, because the claim is about every slice, not
        // about a lucky one.
        for student in 0..<10 {
            let seed = String(repeating: String(format: "%04x", student * 997 + 13), count: 16)
            let out = DatasetMaterializer.materialize(source: pool, spec: spec(size: 20), seedHex: seed)
            let present = Set(wards(out))
            #expect(
                present == ["3A", "3B", "4C", "ICU"],
                "student \(student) lost a category: \(present.sorted())")
        }
    }

    @Test func sampleSizeIsSpentExactly() {
        let pool = lopsidedPool()
        for size in [5, 20, 33, 99] {
            let out = DatasetMaterializer.materialize(source: pool, spec: spec(size: size), seedHex: seedA)
            #expect(wards(out).count == size, "size \(size)")
        }
    }

    @Test func largerStrataGetMoreRows() {
        let out = DatasetMaterializer.materialize(
            source: lopsidedPool(), spec: spec(size: 40), seedHex: seedA)
        var counts: [String: Int] = [:]
        for ward in wards(out) { counts[ward, default: 0] += 1 }
        // 60 / 30 / 9 / 1 of 100 rows, sampled 40 with a floor of one each.
        #expect(counts["3A", default: 0] > counts["3B", default: 0])
        #expect(counts["3B", default: 0] > counts["4C", default: 0])
        #expect(counts["ICU"] == 1, "a stratum never yields more rows than it holds")
    }

    // MARK: - Determinism, the non-negotiable

    @Test func sameSeedSameBytes() {
        let pool = lopsidedPool()
        let first = DatasetMaterializer.materialize(source: pool, spec: spec(size: 25), seedHex: seedA)
        let second = DatasetMaterializer.materialize(source: pool, spec: spec(size: 25), seedHex: seedA)
        #expect(first == second)
    }

    @Test func differentSeedsGenerallyDiffer() {
        let pool = lopsidedPool()
        let a = DatasetMaterializer.materialize(source: pool, spec: spec(size: 25), seedHex: seedA)
        let b = DatasetMaterializer.materialize(source: pool, spec: spec(size: 25), seedHex: seedB)
        #expect(a != b)
    }

    /// The byte-level pin, in the same spirit as `DatasetMaterializerFixtureTests`
    /// — a student's stratified slice must not move either.
    @Test func stratifiedOutputIsPinned() {
        let source = """
            id,ward
            0,3A
            1,3A
            2,3A
            3,3A
            4,3B
            5,3B
            6,3B
            7,4C
            8,4C
            9,ICU

            """
        let out = DatasetMaterializer.materialize(source: source, spec: spec(size: 6), seedHex: seedA)
        #expect(
            out == """
                id,ward
                1,3A
                2,3A
                4,3B
                6,3B
                7,4C
                9,ICU

                """)
    }

    // MARK: - The envelope matches rowSample's

    @Test func headerAndRowOrderPreserved() {
        let out = DatasetMaterializer.materialize(
            source: lopsidedPool(), spec: spec(size: 30), seedHex: seedA)
        #expect(out.hasPrefix("id,ward,score\n"))
        let ids = out.split(separator: "\n").dropFirst().compactMap { Int(DatasetMaterializer.splitCSVLine($0)[0]) }
        #expect(ids == ids.sorted(), "chosen rows keep their original order")
        #expect(Set(ids).count == ids.count, "no duplicate rows")
    }

    @Test func wholeFileWhenTheSampleIsNotAReduction() {
        let pool = lopsidedPool()
        for size in [100, 101, nil] {
            #expect(
                DatasetMaterializer.materialize(source: pool, spec: spec(size: size), seedHex: seedA) == pool,
                "size \(String(describing: size))")
        }
    }

    @Test func crlfAndTrailingNewlineHandledAsInRowSample() {
        let lf = "id,ward\n" + (0..<20).map { "\($0),\($0 % 3)" }.joined(separator: "\n")
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let fromLF = DatasetMaterializer.materialize(source: lf, spec: spec(size: 6), seedHex: seedA)
        let fromCRLF = DatasetMaterializer.materialize(source: crlf, spec: spec(size: 6), seedHex: seedA)
        #expect(!fromCRLF.contains("\r"))
        #expect(fromLF == fromCRLF, "line endings must not perturb selection")
        #expect(!fromLF.hasSuffix("\n"), "a source without a trailing newline yields one without")
    }

    // MARK: - Degrading rather than failing at delivery

    @Test func unknownColumnFallsBackToAPlainRowSample() {
        let pool = lopsidedPool()
        let missing = DatasetMaterializer.materialize(
            source: pool, spec: spec(size: 12, column: "unit"), seedHex: seedA)
        let plain = DatasetMaterializer.materialize(
            source: pool, spec: DatasetSpec(file: "cases.csv", sampleSize: 12), seedHex: seedA)
        #expect(missing == plain, "a column the file lost degrades to rowSample, not to the whole pool")
        #expect(missing != pool)
    }

    @Test func absentColumnNameFallsBackToAPlainRowSample() {
        let pool = lopsidedPool()
        for column in [nil, ""] {
            let out = DatasetMaterializer.materialize(
                source: pool, spec: spec(size: 12, column: column), seedHex: seedA)
            let plain = DatasetMaterializer.materialize(
                source: pool, spec: DatasetSpec(file: "cases.csv", sampleSize: 12), seedHex: seedA)
            #expect(out == plain, "column \(String(describing: column))")
        }
    }

    @Test func rowsMissingTheColumnGroupTogetherRatherThanDropping() {
        // A short row has no value for `ward`; it must still be eligible, or
        // some students would silently receive fewer rows than they asked for.
        let source = """
            id,ward
            0,3A
            1
            2,3A
            3
            4,3B
            5,3B

            """
        let out = DatasetMaterializer.materialize(source: source, spec: spec(size: 4), seedHex: seedA)
        #expect(out.split(separator: "\n").dropFirst().count == 4)
    }

    // MARK: - Apportionment on its own

    @Test func apportionGivesEveryStratumAtLeastOne() {
        let allocation = DatasetMaterializer.apportion(sampleSize: 20, sizes: [60, 30, 9, 1], total: 100)
        #expect(allocation.allSatisfy { $0 >= 1 })
        #expect(allocation.reduce(0, +) == 20)
        #expect(allocation[3] == 1, "a one-row stratum can only ever give one row")
    }

    @Test func apportionIsProportionalOnTheRemainder() {
        // 30 rows of 100, one floor row each, 26 shared out in proportion to
        // the 96 rows that remain after the floor.
        let allocation = DatasetMaterializer.apportion(sampleSize: 30, sizes: [60, 30, 9, 1], total: 100)
        #expect(allocation.reduce(0, +) == 30)
        #expect(allocation[0] > allocation[1])
        #expect(allocation[1] > allocation[2])
        #expect(allocation[3] == 1)
    }

    @Test func apportionNeverExceedsAStratumsRows() {
        let sizes = [2, 2, 96]
        let allocation = DatasetMaterializer.apportion(sampleSize: 50, sizes: sizes, total: 100)
        #expect(allocation.reduce(0, +) == 50)
        for (index, count) in allocation.enumerated() {
            #expect(count <= sizes[index], "stratum \(index) over-allocated")
        }
    }

    @Test func apportionSpendsTheBudgetWhenSmallStrataCapOut() {
        // Every stratum but the last is a singleton, so the leftovers all have
        // to land on the one that can absorb them.
        let sizes = [1, 1, 1, 50]
        let allocation = DatasetMaterializer.apportion(sampleSize: 20, sizes: sizes, total: 53)
        #expect(allocation == [1, 1, 1, 17])
    }

    @Test func apportionWithMoreStrataThanBudgetTakesOneEachInFileOrder() {
        let allocation = DatasetMaterializer.apportion(sampleSize: 2, sizes: [5, 5, 5, 5], total: 20)
        #expect(allocation == [1, 1, 0, 0])
    }

    @Test func apportionIsAFunctionOfItsInputsAlone() {
        let sizes = [17, 4, 39, 1, 8]
        let first = DatasetMaterializer.apportion(sampleSize: 22, sizes: sizes, total: 69)
        let second = DatasetMaterializer.apportion(sampleSize: 22, sizes: sizes, total: 69)
        #expect(first == second)
    }

    // MARK: - CSV field splitting

    @Test func quotedFieldsDoNotShiftLaterColumns() {
        let fields = DatasetMaterializer.splitCSVLine(#"1,"Smith, John",3A,"say ""hi""",7"#)
        #expect(fields == ["1", "Smith, John", "3A", #"say "hi""#, "7"])
    }

    @Test func plainAndEmptyFieldsSplitAsExpected() {
        #expect(DatasetMaterializer.splitCSVLine("a,b,c") == ["a", "b", "c"])
        #expect(DatasetMaterializer.splitCSVLine("a,,c") == ["a", "", "c"])
        #expect(DatasetMaterializer.splitCSVLine("") == [""])
        #expect(DatasetMaterializer.splitCSVLine("a,") == ["a", ""])
    }

    @Test func aQuotedCommaBeforeTheStratumColumnDoesNotMisgroup() {
        // The defect a naive comma split would cause: `ward` read as a slice of
        // the name, so the strata become one-per-row and every "category"
        // survives trivially while the sample is meaningless.
        let source = """
            id,name,ward
            0,"Smith, John",3A
            1,"Doe, Jane",3B
            2,"Roe, Rick",3A
            3,"Poe, Edgar",3B

            """
        let out = DatasetMaterializer.materialize(
            source: source,
            spec: DatasetSpec(
                file: "cases.csv", kind: .stratifiedSample, sampleSize: 2, stratumColumn: "ward"),
            seedHex: seedA)
        let picked = out.split(separator: "\n").dropFirst().map {
            DatasetMaterializer.splitCSVLine($0)[2]
        }
        #expect(Set(picked) == ["3A", "3B"], "one row from each real ward")
    }

    // MARK: - Codable

    @Test func stratifiedSpecRoundTrips() throws {
        let spec = DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, sampleSize: 500, stratumColumn: "ward")
        let decoded = try JSONDecoder().decode(DatasetSpec.self, from: try JSONEncoder().encode(spec))
        #expect(decoded == spec)
    }

    @Test func aSpecPredatingStratificationStillDecodes() throws {
        let decoded = try JSONDecoder().decode(
            DatasetSpec.self, from: Data(#"{"file":"cases.csv","kind":"rowSample","sampleSize":25}"#.utf8))
        #expect(decoded.kind == .rowSample)
        #expect(decoded.stratumColumn == nil)
        #expect(decoded.sampleSize == 25)
    }
}
