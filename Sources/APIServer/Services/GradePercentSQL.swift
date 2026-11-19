// APIServer/Services/GradePercentSQL.swift
//
// `GradePercent.of` as a SQL aggregate, for the folds that take the best
// grade in the database (StudentSubmissionAggregates,
// BestGradePercentByStudentAndSetup).
//
// `GradePercent.of` rounds, except that only a full mark reads 100: 199 of
// 200 points reads 99. An aggregate that took MAX over the raw fraction and
// rounded it once read 100 for that row, so the dashboard and the instructor
// roster could show 100% where every other surface showed 99%. The fold
// below keeps the best full-mark row and the best partial row apart, caps the
// partial one at 99 the way `GradePercent.of` does, and takes the larger.
// Rounding is monotone, so max-then-round equals round-then-max within each
// group, and the result equals the highest `gradePercentValue` of the rows.

import Core
import SQLKit

enum GradePercentSQL {
    /// Two aggregate columns over results aliased `r`: `best_full`, the
    /// highest raw percent among full-mark rows, and `best_partial`, the
    /// highest among the others. A row with no grade columns adds NULL to
    /// both, as `gradePercentValue` reports no grade for it.
    ///
    /// The branches follow `GradeResultSummary.gradePercentValue`: points
    /// when `total_points` is above 0 and `earned_points` is set, else
    /// passed tests over total tests. The operand order matches the Swift
    /// `earned / total * 100`, so the raw percent is bit-identical, and the
    /// full-mark test is `GradePercent.isFullMark`.
    static var foldColumns: SQLQueryString {
        """
        MAX(CASE WHEN \(unsafeRaw: isFullMark) THEN \(unsafeRaw: rawPercent) END) AS best_full,
        MAX(CASE WHEN NOT (\(unsafeRaw: isFullMark)) THEN \(unsafeRaw: rawPercent) END) AS best_partial
        """
    }

    private static let rawPercent = """
        CASE
            WHEN r.total_points > 0 AND r.earned_points IS NOT NULL
                THEN r.earned_points / r.total_points * 100
            WHEN r.total_tests > 0 AND r.pass_count IS NOT NULL
                THEN CAST(r.pass_count AS DOUBLE PRECISION)
                    / CAST(r.total_tests AS DOUBLE PRECISION) * 100
        END
        """

    private static let isFullMark = """
        CASE
            WHEN r.total_points > 0 AND r.earned_points IS NOT NULL
                THEN r.earned_points >= r.total_points - r.total_points * CAST(1e-9 AS DOUBLE PRECISION)
            WHEN r.total_tests > 0 AND r.pass_count IS NOT NULL
                THEN r.pass_count >= r.total_tests
        END
        """

    /// The whole-number percent for one group's two fold columns, by the
    /// rule of `GradePercent.of`. Nil when neither column has a value.
    static func percent(bestFull: Double?, bestPartial: Double?) -> Int? {
        let full = bestFull.map { GradePercent.of(rawPercent: $0, isFullMark: true) }
        let partial = bestPartial.map { GradePercent.of(rawPercent: $0, isFullMark: false) }
        switch (full, partial) {
        case (let full?, let partial?): return max(full, partial)
        case (let full?, nil): return full
        case (nil, let partial?): return partial
        case (nil, nil): return nil
        }
    }
}
