// Core/DatasetTransformApplication.swift
//
// The delivery half of derivation (see docs/datasets.md).  `DatasetMaterializer`
// selects the student's rows; this applies the spec's transforms to them.
//
// Determinism is harder here than for selection, because selection only ever
// COPIES bytes while a transform decides new ones.  Three rules keep it:
//
//   1. No `Double` reaches a delivered byte.  `rate` is an authored number, so
//      it is folded to an integer per-mille ONCE, up front; every per-cell
//      decision after that is integer math.
//   2. Each transform draws from its own stream, sub-seeded on the student's
//      seed plus the step's index, kind and column.  A shared stream would mean
//      appending a second transform re-rolls the first, silently changing data
//      already delivered to every student in the class.
//   3. Nothing iterates a `Dictionary` or `Set`.  Columns are visited in the
//      order the instructor listed them, rows in file order.
//
// A transform that cannot apply leaves the data alone — an unknown column is
// skipped, not guessed at.  `DatasetSpecValidation` refuses at save time
// everything this absorbs at delivery, which is the only reason absorbing it is
// safe: loud while an instructor can fix it, forgiving once the reader is a
// student being graded.

import Foundation

extension DatasetMaterializer {

    /// Applies one transform to an already-selected slice.  `index` is the
    /// step's position in `DatasetSpec.transforms`, and is part of its sub-seed.
    static func apply(
        _ transform: DatasetTransform, at index: Int, to csv: String, seedHex: String
    ) -> String {
        switch transform.kind {
        case .missingValues:
            return blankCells(transform, at: index, in: csv, seedHex: seedHex)
        }
    }

    /// Blanks `rate` of the rows in each named column.
    ///
    /// Returns `csv` untouched when the step cannot apply — no rate, a
    /// non-positive rate, no data rows, or a column the file does not have.
    static func blankCells(
        _ transform: DatasetTransform, at index: Int, in csv: String, seedHex: String
    ) -> String {
        guard let permille = permille(of: transform.rate), permille > 0 else { return csv }
        let (lines, hadTrailingNewline) = normalizedLines(of: csv)
        guard lines.count > 1 else { return csv }

        let headerFields = splitCSVLine(lines[0])
        let rowCount = lines.count - 1
        // The count is fixed before any per-cell work, so no float ever decides
        // which cell is blanked — only how many are.
        let affected = (rowCount * permille) / 1000
        guard affected > 0 else { return csv }

        var rows = lines.map(String.init)
        for column in transform.columns {
            guard let columnIndex = headerFields.firstIndex(of: column) else { continue }
            // Sub-seeded per column as well as per step: adding a column to the
            // list must not move which rows an existing column blanks.
            var rng = SplitMix64(
                seed: fnv1a64(
                    "\(seedHex)|\(index)|\(transform.kind.rawValue)|\(column)"))
            for row in chooseRows(count: affected, of: rowCount, using: &rng) {
                rows[row] = blanking(field: columnIndex, in: rows[row])
            }
        }

        let result = rows.joined(separator: "\n")
        return hadTrailingNewline ? result + "\n" : result
    }

    /// `rate` as thousandths, or nil when it is absent or outside `0 < r <= 1`.
    /// This is the one place the authored `Double` is read; everything
    /// downstream is integer.
    private static func permille(of rate: Double?) -> Int? {
        guard let rate, rate > 0, rate <= 1 else { return nil }
        return Int((rate * 1000).rounded())
    }

    /// `count` distinct row numbers in `1...rowCount`, in ascending order.
    /// Partial Fisher-Yates over the row indices, matching how `sampleRows`
    /// chooses rows so the two read the same way.
    private static func chooseRows(
        count: Int, of rowCount: Int, using rng: inout SplitMix64
    ) -> [Int] {
        var indices = Array(1...rowCount)
        let take = min(count, rowCount)
        for i in 0..<take {
            let j = i + Int(rng.next(upperBound: UInt64(rowCount - i)))
            indices.swapAt(i, j)
        }
        return indices.prefix(take).sorted()
    }

    /// `line` with field `index` replaced by an empty value.
    ///
    /// Edits the raw text in place rather than splitting and re-joining: a
    /// rebuild would re-quote every OTHER field by this file's rules rather than
    /// the source's, changing bytes in cells the transform was never asked to
    /// touch.  A short row (fewer fields than the header) is returned unchanged.
    private static func blanking(field index: Int, in line: String) -> String {
        let ranges = fieldRanges(of: Substring(line))
        guard index < ranges.count else { return line }
        return line.replacingCharacters(in: ranges[index], with: "")
    }

    /// The raw span of each comma-separated field in `line`, using the same
    /// quoting rules as `splitCSVLine` — a comma inside quotes is data, and a
    /// doubled quote is an escaped one — so the two always agree on how many
    /// fields a line has.
    static func fieldRanges(of line: Substring) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var fieldStart = line.startIndex
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let character = line[i]
            if inQuotes {
                if character == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        i = line.index(after: next)  // an escaped quote
                        continue
                    }
                    inQuotes = false
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                ranges.append(fieldStart..<i)
                fieldStart = line.index(after: i)
            }
            i = line.index(after: i)
        }
        ranges.append(fieldStart..<line.endIndex)
        return ranges
    }
}
