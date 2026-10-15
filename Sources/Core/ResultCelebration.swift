// Core/ResultCelebration.swift
//
// Which celebration a student's result page plays (docs/result-celebration.md,
// J1). The server chooses it and renders it as data attributes; the page
// script reads them and decides nothing more.
//
// A celebration only ever marks a gain. A result that is the same or lower
// plays nothing, so the bird never looks sad about a grade
// (Core/AvatarReaction.swift).

/// The celebration a graded result plays.
public enum ResultCelebration: String, Codable, Sendable, Equatable {
    /// 100% now, and no earlier attempt reached 100%: the full sequence with
    /// the feather burst.
    case first
    /// Below 100%, and higher than the previous graded attempt: the count-up
    /// from the previous percent, one hop and a "+N" chip.
    case improved
    /// 100% now, and an earlier attempt also reached 100%: a sparkle only.
    case already

    /// The celebration for a result of `percent`, or nil when nothing plays.
    ///
    /// - Parameters:
    ///   - percent: this attempt's autograded percent (`GradePercent.of`),
    ///     nil when it has no points to grade.
    ///   - previousPercent: the percent of the previous graded attempt on the
    ///     same assignment, nil when there is none.
    ///   - earlierBestPercent: the highest percent of every earlier graded
    ///     attempt on the same assignment, nil when there is none.
    public init?(percent: Int?, previousPercent: Int?, earlierBestPercent: Int?) {
        guard let percent else { return nil }
        if percent >= 100 {
            self = (earlierBestPercent ?? 0) >= 100 ? .already : .first
        } else if let previousPercent, percent > previousPercent {
            self = .improved
        } else {
            return nil
        }
    }
}
