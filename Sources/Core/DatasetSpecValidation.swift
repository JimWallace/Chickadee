// Core/DatasetSpecValidation.swift
//
// The save-time half of the stratified-sampling contract (docs/datasets.md
// Phase 1.5).
//
// `DatasetMaterializer` degrades quietly when a stratified spec does not fit
// its file — an unknown column falls back to a plain row sample — because by
// delivery time the only reader is a student being graded, and there is nothing
// they could do about an error. That forgiveness is only safe if the mistake is
// caught somewhere it CAN be fixed, which is here: every authoring door runs
// this before writing a spec, so a typo'd column name is refused in the second
// it is typed rather than silently unstratifying a whole class's data.
//
// It answers about the spec and the file's text alone — no zip, no database, no
// Vapor — so the web endpoints and the MCP tool ask one question and get one
// answer, and each wraps the result in its own error type.

import Foundation

/// Save-time checks a dataset spec must pass against the file it marks.
public enum DatasetSpecValidation {

    /// How many column names an error message lists before trailing off. A
    /// clinical extract can have hundreds; a wall of them helps nobody.
    static let maxListedColumns = 12

    /// Returns why `spec` cannot be saved against `sourceCSV`, or nil when it
    /// is fine.
    ///
    /// `sourceCSV` is the marked file's text, or nil when the file's bytes are
    /// not UTF-8 — which is itself a rejection for a stratified spec, since the
    /// column cannot be found in bytes that are not a text table.
    ///
    /// The message is user-facing: it names what is wrong, and where the answer
    /// is knowable (the available columns, the number of categories) it says
    /// that too, because the instructor cannot see the file from the form they
    /// are typing into.
    public static func issue(with spec: DatasetSpec, sourceCSV: String?) -> String? {
        if let issue = transformIssue(with: spec, sourceCSV: sourceCSV) { return issue }
        return selectionIssue(with: spec, sourceCSV: sourceCSV)
    }

    /// Why `spec`'s transform list cannot be saved, or nil.
    ///
    /// Every check here pairs with something `DatasetMaterializer` absorbs
    /// silently at delivery: a step with no columns, an unknown column, a
    /// missing or out-of-range rate, and a rate too small to reach one row of
    /// the student's sample all leave the data untouched. Untouched data is the
    /// right answer for a student being graded and the wrong answer for an
    /// instructor who thinks they asked for something.
    static func transformIssue(with spec: DatasetSpec, sourceCSV: String?) -> String? {
        guard !spec.transforms.isEmpty else { return nil }
        let columns = sourceCSV.flatMap { csv -> [String]? in
            let rows = csv.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true)
            return rows.first.map { DatasetMaterializer.splitCSVLine($0) }
        }

        var seen: Set<String> = []
        for transform in spec.transforms {
            let label = "'\(spec.file)': \(transform.kind.rawValue)"
            guard !transform.columns.isEmpty else {
                return "\(label) names no column, so it would change nothing."
            }
            for column in transform.columns {
                guard let columns else {
                    return "'\(spec.file)' is not UTF-8 text, so it has no columns to transform."
                }
                guard columns.contains(column) else {
                    return "\(label): '\(spec.file)' has no column named '\(column)'. "
                        + "Its columns are: \(list(columns))."
                }
                // Two steps of one kind on one column would each blank a
                // different subset and the result would depend on their order
                // in a way nobody authored.
                guard seen.insert("\(transform.kind.rawValue)|\(column)").inserted else {
                    return "\(label) is applied to '\(column)' more than once."
                }
            }
            if let issue = rateIssue(transform, spec: spec, label: label) { return issue }
        }
        return nil
    }

    /// A rate must be present, within `0 < rate <= 1`, and large enough to reach
    /// at least one row of the sample the student actually receives — the
    /// integer fold `(rows * permille) / 1000` is what delivery uses, so a rate
    /// below one row's worth silently does nothing.
    private static func rateIssue(
        _ transform: DatasetTransform, spec: DatasetSpec, label: String
    ) -> String? {
        guard let rate = transform.rate else {
            return "\(label) needs a rate — the fraction of rows to affect, above 0 and at most 1."
        }
        guard rate > 0, rate <= 1 else {
            return "\(label): a rate of \(rate) is outside the allowed range (above 0, at most 1)."
        }
        guard let sampleSize = spec.sampleSize else { return nil }
        let permille = Int((rate * 1000).rounded())
        guard (sampleSize * permille) / 1000 > 0 else {
            return "\(label): a rate of \(rate) over a \(sampleSize)-row sample affects no rows. "
                + "Raise the rate, or the sample size."
        }
        return nil
    }

    private static func selectionIssue(with spec: DatasetSpec, sourceCSV: String?) -> String? {
        guard spec.kind == .stratifiedSample else {
            // A column on a plain row sample would be stored and then ignored
            // at delivery — the silent-mismatch shape this whole file exists to
            // prevent — so it is refused rather than dropped.
            if let column = spec.stratumColumn, !column.isEmpty {
                return "'\(spec.file)': a stratum column only applies to a stratified sample."
            }
            return nil
        }

        guard let column = spec.stratumColumn?.trimmingCharacters(in: .whitespaces), !column.isEmpty else {
            return "'\(spec.file)': a stratified sample needs the name of the column to balance across."
        }
        guard let sourceCSV else {
            return "'\(spec.file)' is not UTF-8 text, so it has no columns to balance across."
        }

        let rows = sourceCSV.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = rows.first else {
            return "'\(spec.file)' is empty, so it has no columns to balance across."
        }

        let columns = DatasetMaterializer.splitCSVLine(header)
        guard let columnIndex = columns.firstIndex(of: column) else {
            return "'\(spec.file)' has no column named '\(column)'. Its columns are: \(list(columns))."
        }

        // The instructor's real question is "will every category survive?", and
        // it is answerable here and nowhere else: a sample smaller than the
        // number of categories cannot include them all, whatever the
        // apportionment does.
        var categories: Set<String> = []
        for row in rows.dropFirst() {
            let fields = DatasetMaterializer.splitCSVLine(row)
            categories.insert(columnIndex < fields.count ? fields[columnIndex] : "")
        }
        if let sampleSize = spec.sampleSize, sampleSize < categories.count {
            return
                "'\(spec.file)': column '\(column)' has \(categories.count) distinct values, so a sample "
                + "of \(sampleSize) rows cannot include them all. Raise the sample size to at least "
                + "\(categories.count), or balance across a column with fewer categories."
        }
        return nil
    }

    private static func list(_ columns: [String]) -> String {
        let shown = columns.prefix(maxListedColumns).map { "'\($0)'" }.joined(separator: ", ")
        return columns.count > maxListedColumns ? shown + ", …" : shown
    }
}
