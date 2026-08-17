// Core/DatasetMaterializer.swift
//
// Deterministic per-student dataset slicing (Phase 1 — see docs/datasets.md).
//
// The server resolves a student's slice ONCE from the per-(student,
// assignment) seed and delivers the resulting bytes to every consumer (the
// JupyterLite editor, the worker job, the browser runner).  Nobody
// re-materializes, so there is a single implementation and no cross-runtime
// drift.  That makes determinism the whole job of this file: the same
// (source, spec, seed) must yield byte-identical output on macOS and Linux,
// across Swift versions, forever — a student's `describe()` numbers in the
// editor must match what the worker grades.
//
// To guarantee that we avoid every process-salted / version-variable source
// of randomness (`Hasher`, `String.hashValue`, `SystemRandomNumberGenerator`,
// `Array.shuffle(using:)`) and use only explicit integer math: an FNV-1a hash
// of the seed hex drives a hand-rolled SplitMix64 PRNG, consumed by a manual
// partial Fisher-Yates selection.

import Foundation

/// Produces a student's slice of a source support file.
public enum DatasetMaterializer {

    /// Materialize `source` for the given spec and per-student seed.
    /// Returns the source unchanged for any kind/size that implies "the whole
    /// file" so callers can deliver the result unconditionally.
    ///
    /// Selection first, then each transform in array order — so a transform's
    /// rate applies to the rows the student actually receives rather than to the
    /// pool, and appending a step never re-decides an earlier one.
    public static func materialize(source: String, spec: DatasetSpec, seedHex: String) -> String {
        let selected = select(source: source, spec: spec, seedHex: seedHex)
        guard !spec.transforms.isEmpty else { return selected }
        return spec.transforms.enumerated().reduce(selected) { csv, step in
            apply(step.element, at: step.offset, to: csv, seedHex: seedHex)
        }
    }

    private static func select(source: String, spec: DatasetSpec, seedHex: String) -> String {
        switch spec.kind {
        case .rowSample:
            return sampleRows(csv: source, sampleSize: spec.sampleSize ?? .max, seedHex: seedHex)
        case .stratifiedSample:
            // A stratified spec with no column, or one naming a column this
            // file does not have, degrades to a plain row sample rather than
            // failing. Authoring refuses both (see `DatasetSpec.stratumColumn`),
            // so reaching here means the file changed under a saved spec — and
            // the only reader left is a student being graded, who would rather
            // have their N rows unstratified than the whole pool everyone else
            // has. Loud at authoring, forgiving at delivery.
            guard let column = spec.stratumColumn, !column.isEmpty else {
                return sampleRows(csv: source, sampleSize: spec.sampleSize ?? .max, seedHex: seedHex)
            }
            return sampleStratifiedRows(
                csv: source, sampleSize: spec.sampleSize ?? .max, column: column, seedHex: seedHex)
        }
    }

    /// Deterministically sample `sampleSize` data rows from a CSV `csv`,
    /// preserving the header and the original order of the chosen rows.
    ///
    /// Line endings are normalized to `\n` (a sampled result is always
    /// LF-terminated); a trailing newline is preserved if the input had one.
    /// Row-level splitting assumes records are not split across physical lines
    /// (no quoted embedded newlines) — true for the tabular health datasets
    /// this targets (e.g. VitalDB case tables).  Returns `csv` unchanged when
    /// it has no data rows, when `sampleSize` is non-positive, or when
    /// `sampleSize` is ≥ the number of data rows.
    static func sampleRows(csv: String, sampleSize: Int, seedHex: String) -> String {
        let (lines, hadTrailingNewline) = normalizedLines(of: csv)
        guard lines.count > 1 else { return csv }  // header-only or empty

        let header = lines[0]
        let dataRows = lines[1...]
        let rowCount = dataRows.count
        guard sampleSize > 0, sampleSize < rowCount else { return csv }  // keep everything

        var rng = SplitMix64(seed: fnv1a64(seedHex))
        var indices = Array(dataRows.indices)  // indices into `lines`
        // Partial Fisher-Yates: shuffle the first `sampleSize` slots into place.
        for i in 0..<sampleSize {
            let j = i + Int(rng.next(upperBound: UInt64(rowCount - i)))
            indices.swapAt(i, j)
        }
        let chosen = indices.prefix(sampleSize).sorted()

        var out: [Substring] = [header]
        out.append(contentsOf: chosen.map { lines[$0] })
        let result = out.joined(separator: "\n")
        return hadTrailingNewline ? result + "\n" : result
    }

    /// Deterministically sample `sampleSize` data rows apportioned across the
    /// distinct values of `column`, so every category in the pool survives into
    /// the student's slice.
    ///
    /// Same envelope as `sampleRows`: header preserved, chosen rows in original
    /// order, LF output, trailing newline mirrored, and the whole file returned
    /// unchanged when the sample would not be a reduction.  Falls back to a
    /// plain row sample when `column` is not in the header — the delivery-time
    /// half of the rule on `DatasetSpec.stratumColumn`.
    ///
    /// Apportionment is Hamilton's method with a floor of one row per stratum,
    /// computed in integer arithmetic (no `Double`: the point of this file is
    /// that the same inputs give the same bytes on every platform forever, and
    /// a rounding difference would be an invisible way to lose that).  When the
    /// budget cannot cover one row per stratum — the file grew categories after
    /// the spec was saved — the first `sampleSize` strata in file order get one
    /// row each.
    static func sampleStratifiedRows(
        csv: String, sampleSize: Int, column: String, seedHex: String
    ) -> String {
        let (lines, hadTrailingNewline) = normalizedLines(of: csv)
        guard lines.count > 1 else { return csv }  // header-only or empty

        let header = lines[0]
        let rowCount = lines.count - 1
        guard sampleSize > 0, sampleSize < rowCount else { return csv }  // keep everything

        let headerFields = splitCSVLine(header)
        guard let columnIndex = headerFields.firstIndex(of: column) else {
            return sampleRows(csv: csv, sampleSize: sampleSize, seedHex: seedHex)
        }

        // Strata in order of first appearance — a stable order that needs no
        // string comparison, so no question of collation ever arises.
        var strataOrder: [String] = []
        var rowsByStratum: [String: [Int]] = [:]
        for index in 1..<lines.count {
            let fields = splitCSVLine(lines[index])
            // A short row has no value for this column; "" is a category like
            // any other, and grouping it keeps every row eligible.
            let value = columnIndex < fields.count ? fields[columnIndex] : ""
            if rowsByStratum[value] == nil {
                rowsByStratum[value] = []
                strataOrder.append(value)
            }
            rowsByStratum[value]?.append(index)
        }

        let sizes = strataOrder.map { rowsByStratum[$0]?.count ?? 0 }
        let allocation = apportion(sampleSize: sampleSize, sizes: sizes, total: rowCount)

        // One PRNG stream walked in stratum order, so the whole slice is one
        // deterministic sequence rather than N independent ones.
        var rng = SplitMix64(seed: fnv1a64(seedHex))
        var chosen: [Int] = []
        for (position, stratum) in strataOrder.enumerated() {
            guard var indices = rowsByStratum[stratum] else { continue }
            let take = allocation[position]
            if take <= 0 { continue }
            if take >= indices.count {
                chosen.append(contentsOf: indices)
                continue
            }
            for i in 0..<take {
                let j = i + Int(rng.next(upperBound: UInt64(indices.count - i)))
                indices.swapAt(i, j)
            }
            chosen.append(contentsOf: indices.prefix(take))
        }
        chosen.sort()

        var out: [Substring] = [header]
        out.append(contentsOf: chosen.map { lines[$0] })
        let result = out.joined(separator: "\n")
        return hadTrailingNewline ? result + "\n" : result
    }

    /// Splits `sampleSize` across strata: one row each, then the remainder in
    /// proportion to stratum size, leftovers to the largest fractional
    /// remainders (ties to the earlier stratum).  Never allocates more rows
    /// than a stratum holds.
    ///
    /// Returns counts parallel to `sizes`.  Internal rather than private so the
    /// apportionment can be tested on its own — the row selection around it is
    /// seeded, and a table of expected splits is far easier to read than a
    /// slice of a CSV.
    static func apportion(sampleSize: Int, sizes: [Int], total: Int) -> [Int] {
        guard !sizes.isEmpty else { return [] }
        // More strata than rows to give away: one row each to as many strata as
        // the budget covers, in file order.
        guard sampleSize > sizes.count else {
            return sizes.indices.map { $0 < sampleSize ? 1 : 0 }
        }

        var allocation = sizes.map { min(1, $0) }
        // Hamilton over the rows left after the floor, against each stratum's
        // remaining capacity.
        let spare = sizes.map { max(0, $0 - 1) }
        let spareTotal = spare.reduce(0, +)
        let remaining = sampleSize - allocation.reduce(0, +)
        if remaining > 0, spareTotal > 0 {
            var remainders: [(index: Int, remainder: Int)] = []
            for i in sizes.indices {
                let exact = spare[i] * remaining
                allocation[i] += exact / spareTotal
                remainders.append((i, exact % spareTotal))
            }
            var leftover = sampleSize - allocation.reduce(0, +)
            // Largest remainder first; ties by position, so the split is a
            // function of the inputs alone.
            remainders.sort { $0.remainder == $1.remainder ? $0.index < $1.index : $0.remainder > $1.remainder }
            var pass = 0
            while leftover > 0, pass < remainders.count {
                let i = remainders[pass].index
                if allocation[i] < sizes[i] {
                    allocation[i] += 1
                    leftover -= 1
                }
                pass += 1
            }
            // A stratum can be capped out while another still has room (the
            // proportional pass does not know about caps), so sweep in file
            // order until the budget is spent or nothing can absorb it.
            var progressed = true
            while leftover > 0, progressed {
                progressed = false
                for i in sizes.indices where leftover > 0 && allocation[i] < sizes[i] {
                    allocation[i] += 1
                    leftover -= 1
                    progressed = true
                }
            }
        }
        return allocation
    }

    /// Splits `csv` into lines with CR/CRLF normalized away, reporting whether
    /// the input ended with a newline.  Shared by both sampling kinds so their
    /// line handling cannot drift.
    ///
    /// CR+LF is a single Swift `Character` (one extended grapheme cluster), so
    /// `split(separator: "\n")` would not see the LF inside a CRLF ending and
    /// would return the whole file as one "line".
    static func normalizedLines(of csv: String) -> (lines: [Substring], trailingNewline: Bool) {
        let normalized = csv.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if hadTrailingNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return (lines, hadTrailingNewline)
    }

    /// Splits one CSV record into fields, honouring double-quoted fields and
    /// doubled quotes inside them.
    ///
    /// Quotes matter here even though the surrounding format assumes no
    /// embedded newlines: a quoted comma ANYWHERE earlier in the row shifts
    /// every later field by one, so a naive comma split would read a
    /// neighbouring column's values as the strata and silently stratify by the
    /// wrong thing. Embedded newlines remain out of scope — a record is a
    /// physical line, as `sampleRows` has always assumed.
    static func splitCSVLine(_ line: Substring) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")  // an escaped quote
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"": inQuotes = true
            case ",":
                fields.append(current)
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}

/// Deterministic, seedable PRNG (SplitMix64).  Pure integer math, so its
/// output is identical across platforms and Swift versions — unlike the
/// standard library's `RandomNumberGenerator` helpers, whose bit-consumption
/// is not a stable contract.  Intentionally not conforming to
/// `RandomNumberGenerator` to keep callers off `random(in:using:)`.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Unbiased value in `0..<upperBound` via rejection sampling.
    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 1 else { return 0 }
        let limit = UInt64.max - (UInt64.max % upperBound)
        var r = next()
        while r >= limit { r = next() }
        return r % upperBound
    }
}

/// FNV-1a 64-bit hash over a string's UTF-8 bytes.  Deterministic and
/// dependency-free — used only to fold a 64-hex seed into a PRNG seed.
func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}
