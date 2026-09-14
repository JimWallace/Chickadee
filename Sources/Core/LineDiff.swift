// Core/LineDiff.swift
//
// A line-level diff rendered as a unified listing: every changed line, with
// long unchanged runs folded behind a count. Built on the standard library's
// `difference(from:)` (a Myers-style LCS), so there is no algorithm to
// maintain here — only the walk that turns the edit script into rows.
//
// Vapor-free so the instructor diff page and its tests can use it without a
// request, and so a future "diff two attempts" view can share it.

/// One row of a unified diff listing.
public struct LineDiffRow: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Present in both sides.
        case context
        /// Present only in the new side.
        case added
        /// Present only in the old side.
        case removed
        /// A run of unchanged lines collapsed behind a count; `text` carries
        /// the count and the line numbers say where the run started.
        case fold
    }

    public let kind: Kind
    /// 1-based line number on the old side, nil for an added line.
    public let oldNumber: Int?
    /// 1-based line number on the new side, nil for a removed line.
    public let newNumber: Int?
    public let text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public enum LineDiff {

    /// The rows of a unified diff from `old` to `new`, keeping `context`
    /// unchanged lines on each side of a change and folding longer runs.
    /// `context: nil` keeps every line.
    public static func unified(old: [String], new: [String], context: Int? = 3) -> [LineDiffRow] {
        let full = fullListing(old: old, new: new)
        guard let context else { return full }
        return fold(full, context: context)
    }

    /// Added and removed line counts for a summary line.
    public static func counts(_ rows: [LineDiffRow]) -> (added: Int, removed: Int) {
        (
            rows.filter { $0.kind == .added }.count,
            rows.filter { $0.kind == .removed }.count
        )
    }

    /// Every line of both sides in one listing, no folding.
    private static func fullListing(old: [String], new: [String]) -> [LineDiffRow] {
        let difference = new.difference(from: old)
        let removedOffsets = Set(
            difference.removals.compactMap { change -> Int? in
                if case .remove(let offset, _, _) = change { return offset }
                return nil
            })
        let insertedOffsets = Set(
            difference.insertions.compactMap { change -> Int? in
                if case .insert(let offset, _, _) = change { return offset }
                return nil
            })

        var rows: [LineDiffRow] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removedOffsets.contains(oldIndex) {
                rows.append(
                    LineDiffRow(kind: .removed, oldNumber: oldIndex + 1, newNumber: nil, text: old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count, insertedOffsets.contains(newIndex) {
                rows.append(
                    LineDiffRow(kind: .added, oldNumber: nil, newNumber: newIndex + 1, text: new[newIndex]))
                newIndex += 1
            } else {
                rows.append(
                    LineDiffRow(
                        kind: .context, oldNumber: oldIndex + 1, newNumber: newIndex + 1,
                        text: old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }
        return rows
    }

    /// Collapses each run of context lines longer than `2 * context + 1`
    /// into its leading and trailing `context` lines around one fold row.
    private static func fold(_ rows: [LineDiffRow], context: Int) -> [LineDiffRow] {
        var result: [LineDiffRow] = []
        var run: [LineDiffRow] = []

        func flush(isTail: Bool, isHead: Bool) {
            let keepLeading = isHead ? 0 : context
            let keepTrailing = isTail ? 0 : context
            if run.count > keepLeading + keepTrailing + 1 {
                result.append(contentsOf: run.prefix(keepLeading))
                let hidden = run.count - keepLeading - keepTrailing
                let first = run[keepLeading]
                let noun = hidden == 1 ? "line" : "lines"
                result.append(
                    LineDiffRow(
                        kind: .fold, oldNumber: first.oldNumber, newNumber: first.newNumber,
                        text: "\(hidden) unchanged \(noun)"))
                result.append(contentsOf: run.suffix(keepTrailing))
            } else {
                result.append(contentsOf: run)
            }
            run.removeAll()
        }

        var seenChange = false
        for row in rows {
            if row.kind == .context {
                run.append(row)
            } else {
                flush(isTail: false, isHead: !seenChange)
                seenChange = true
                result.append(row)
            }
        }
        flush(isTail: true, isHead: !seenChange)
        return result
    }
}
