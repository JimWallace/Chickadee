// Core/GradePercent.swift
//
// The one rule that turns earned points into the whole-number percent a grade
// shows and every achievement reads (#2018).

/// The grade as a whole-number percent.
public enum GradePercent {

    /// `earned` over `total` as a percent, rounded to the nearest whole number,
    /// except that only a full mark reads 100. Rounding alone made 199 of 200
    /// points read 100, which earned perfect-score badges, records and class
    /// goals for an imperfect score. Nil when `total` is not above zero.
    public static func of(earned: Double, total: Double) -> Int? {
        guard total > 0 else { return nil }
        let percent = Int((earned / total * 100).rounded())
        if percent >= 100, !isFullMark(earned: earned, total: total) { return 99 }
        return percent
    }

    /// True when `earned` reaches `total`. Points are sums of fractional
    /// scores, so a full mark can land a floating-point error below the total.
    public static func isFullMark(earned: Double, total: Double) -> Bool {
        earned >= total - total * 1e-9
    }
}
