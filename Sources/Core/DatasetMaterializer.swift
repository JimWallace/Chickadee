// Core/DatasetMaterializer.swift
//
// Deterministic per-student dataset slicing (Phase 1 — see docs/datasets.md).
//
// The server resolves a student's slice ONCE from the per-(student,
// assignment) seed and delivers the resulting bytes to every consumer (the
// JupyterLite editor, the worker job, the browser runner).  Nobody
// re-materializes, so there is a single implementation and no cross-runtime
// drift.  That makes determinism the whole job of this file: the same
// (master, spec, seed) must yield byte-identical output on macOS and Linux,
// across Swift versions, forever — a student's `describe()` numbers in the
// editor must match what the worker grades.
//
// To guarantee that we avoid every process-salted / version-variable source
// of randomness (`Hasher`, `String.hashValue`, `SystemRandomNumberGenerator`,
// `Array.shuffle(using:)`) and use only explicit integer math: an FNV-1a hash
// of the seed hex drives a hand-rolled SplitMix64 PRNG, consumed by a manual
// partial Fisher-Yates selection.

/// Produces a student's slice of a master support file.
public enum DatasetMaterializer {

    /// Materialize `master` for the given spec and per-student seed.
    /// Returns the master unchanged for any kind/size that implies "the whole
    /// file" so callers can deliver the result unconditionally.
    public static func materialize(master: String, spec: DatasetSpec, seedHex: String) -> String {
        switch spec.kind {
        case .rowSample:
            return sampleRows(csv: master, sampleSize: spec.sampleSize ?? .max, seedHex: seedHex)
        }
    }

    /// Deterministically sample `sampleSize` data rows from a CSV `csv`,
    /// preserving the header and the original order of the chosen rows.
    ///
    /// Line endings are normalized to `\n`; a trailing newline is preserved if
    /// the input had one.  Row-level splitting assumes records are not split
    /// across physical lines (no quoted embedded newlines) — true for the
    /// tabular health datasets this targets (e.g. VitalDB case tables).
    /// Returns `csv` unchanged when it has no data rows, when `sampleSize` is
    /// non-positive, or when `sampleSize` is ≥ the number of data rows.
    static func sampleRows(csv: String, sampleSize: Int, seedHex: String) -> String {
        let hadTrailingNewline = csv.hasSuffix("\n")
        var lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? $0.dropLast() : $0
        }
        if hadTrailingNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
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
}

/// Deterministic, seedable PRNG (SplitMix64).  Pure integer math, so its
/// output is identical across platforms and Swift versions — unlike the
/// standard library's `RandomNumberGenerator` helpers, whose bit-consumption
/// is not a stable contract.  Intentionally not conforming to
/// `RandomNumberGenerator` to keep callers off `random(in:using:)`.
private struct SplitMix64 {
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
private func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}
