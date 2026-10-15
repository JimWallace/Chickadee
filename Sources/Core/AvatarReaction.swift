// Core/AvatarReaction.swift
//
// How a student's bird reacts to one of their own submission results.
//
// A reaction is chosen when the page renders and is never stored: it changes
// what the bird shows on that one page, not the student's bird. The bird
// reacts only to a clean pass. A partial or failed result shows the bird as
// it is, because a bird that looks sad about a grade turns a cosmetic into a
// verdict.

/// The bird's reaction to one submission result.
public enum AvatarReaction: String, Codable, Sendable, Equatable {
    /// The bird as it is stored.
    case none
    /// Every test passed: the bird chirps.
    case cheer

    /// The reaction to a graded result. A pending result, a failed build or a
    /// result with no tests gets none.
    public init(passCount: Int, totalTests: Int, buildFailed: Bool, isPending: Bool) {
        let passedAll = !isPending && !buildFailed && totalTests > 0 && passCount == totalTests
        self = passedAll ? .cheer : .none
    }

    /// `spec` as the bird shows it during this reaction. The cheer borrows the
    /// `chirp` face for the page; the stored expression does not change, and
    /// borrowing a face does not unlock it.
    public func applied(to spec: AvatarSpec) -> AvatarSpec {
        var shown = spec
        if self == .cheer {
            shown.expression = .chirp
        }
        return shown
    }
}
