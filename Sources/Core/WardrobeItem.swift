// Core/WardrobeItem.swift
//
// The wardrobe items a student earns by their work, and the rule for each
// (docs/student-wardrobe.md, W3; #2592). An unlock is sticky: once earned it
// is stored and kept, even if a regrade later changes the result that earned
// it. Unlocks are account-wide, and the wardrobe stays lateral: an earned
// item is different, not better.
//
// The rules read only what a student's own graded work already records, so
// no instructor sets anything up. They are checked away from the grading
// path (when the account page loads), so a cosmetic can never fail a grade.

/// One earnable option of one customizable slot. The raw value is stored, so
/// it is append-only: never rename or reorder a case.
public enum WardrobeItem: String, CaseIterable, Codable, Sendable {
    /// The `chirp` face, for a first graded submission.
    case chirpFace = "expression.chirp"
    /// The `sly` face, for a first attempt on which every test passes.
    case slyFace = "expression.sly"
    /// The two-tone ring, for every test passing on three different
    /// assignments.
    case twoToneRing = "border.twotone"
    /// The `dreamy` face, for a graded submission well before the due date
    /// on three different assignments (docs/student-wardrobe.md, E4).
    case dreamyFace = "expression.dreamy"
    /// The stitched ring, for a comeback on three different assignments:
    /// every test passing after an earlier attempt where some did not.
    case stitchedRing = "border.stitched"

    /// The slot the item belongs to.
    public var slot: AvatarCustomizableSlot {
        switch self {
        case .chirpFace, .slyFace, .dreamyFace: .expression
        case .twoToneRing, .stitchedRing: .border
        }
    }

    /// The slot's raw value the item opens.
    public var value: String {
        switch self {
        case .chirpFace: AvatarExpression.chirp.rawValue
        case .slyFace: AvatarExpression.sly.rawValue
        case .twoToneRing: AvatarBorder.twotone.rawValue
        case .dreamyFace: AvatarExpression.dreamy.rawValue
        case .stitchedRing: AvatarBorder.stitched.rawValue
        }
    }

    /// The item that opens `value` in `slot`, if any.
    public init?(slot: AvatarCustomizableSlot, value: String) {
        guard let item = Self.allCases.first(where: { $0.slot == slot && $0.value == value }) else { return nil }
        self = item
    }

    /// How a student earns the item, as the account page says it after
    /// "earned": "Chirp · earned by a first graded submission".
    public var howToEarn: String {
        switch self {
        case .chirpFace: "by a first graded submission"
        case .slyFace: "when every test passes on a first attempt"
        case .twoToneRing: "when every test passes on three assignments"
        case .dreamyFace: "by submitting two days early on three assignments"
        case .stitchedRing: "for a comeback on three assignments"
        }
    }

    /// The full-marks assignments the two-tone ring needs.
    public static let fullMarksAssignmentsForTwoTone = 3
    /// The early assignments the `dreamy` face needs.
    public static let earlyAssignmentsForDreamy = 3
    /// The comeback assignments the stitched ring needs.
    public static let comebackAssignmentsForStitched = 3

    /// The items `progress` earns.
    public static func earned(by progress: WardrobeProgress) -> Set<WardrobeItem> {
        var items: Set<WardrobeItem> = []
        if progress.hasGradedSubmission { items.insert(.chirpFace) }
        if progress.hasFirstTryFullMarks { items.insert(.slyFace) }
        if progress.fullMarksAssignments >= fullMarksAssignmentsForTwoTone { items.insert(.twoToneRing) }
        if progress.earlyAssignments >= earlyAssignmentsForDreamy { items.insert(.dreamyFace) }
        if progress.comebackAssignments >= comebackAssignmentsForStitched { items.insert(.stitchedRing) }
        return items
    }
}
