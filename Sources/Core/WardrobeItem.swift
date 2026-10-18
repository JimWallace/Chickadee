// Core/WardrobeItem.swift
//
// The wardrobe items a student earns by their work, and the rule for each
// (docs/student-wardrobe.md, W3; #2592). An unlock is sticky: once earned it
// is stored and kept, even if a regrade later changes the result that earned
// it. Unlocks are account-wide, and the wardrobe stays lateral: an earned
// item is different, not better.
//
// The rules read what a student's own graded work already records. The
// concept rings also read the concept an instructor tagged an assignment with
// (`AssignmentConcept`), the one rule that needs instructor setup. The rules
// are checked away from the grading path (when the account page or a result
// page loads), so a cosmetic can never fail a grade.

import Foundation

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
    /// The concept rings, one for each `AssignmentConcept`, for every test
    /// passing on an assignment tagged with that concept.
    case lifeRing = "border.lifering"
    case greenLightRing = "border.greenlight"
    case ouroborosRing = "border.ouroboros"
    case functionRing = "border.function"
    case binaryRing = "border.binary"
    case pulseRing = "border.pulse"

    /// The slot the item belongs to.
    public var slot: AvatarCustomizableSlot {
        switch self {
        case .chirpFace, .slyFace, .dreamyFace: .expression
        case .twoToneRing, .stitchedRing, .lifeRing, .greenLightRing, .ouroborosRing, .functionRing, .binaryRing,
            .pulseRing:
            .border
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
        case .lifeRing: AvatarBorder.lifering.rawValue
        case .greenLightRing: AvatarBorder.greenlight.rawValue
        case .ouroborosRing: AvatarBorder.ouroboros.rawValue
        case .functionRing: AvatarBorder.function.rawValue
        case .binaryRing: AvatarBorder.binary.rawValue
        case .pulseRing: AvatarBorder.pulse.rawValue
        }
    }

    /// The item that opens `value` in `slot`, if any.
    public init?(slot: AvatarCustomizableSlot, value: String) {
        guard let item = Self.allCases.first(where: { $0.slot == slot && $0.value == value }) else { return nil }
        self = item
    }

    /// The name a student reads in the picker: "Chirp", "Two-tone".
    public var displayName: String {
        switch slot {
        case .expression: AvatarExpression(rawValue: value)?.displayName ?? value
        case .border: AvatarBorder(rawValue: value)?.displayName ?? value
        case .backdrop: value.capitalized
        }
    }

    /// How the student earned the item, in the past tense, as the result
    /// page's Earned toast says it after "Earned": "Earned by a first graded
    /// submission." (docs/student-wardrobe.md, E2).
    public var howEarned: String {
        switch self {
        case .chirpFace: "by a first graded submission"
        case .slyFace: "when every test passed on a first attempt"
        case .twoToneRing: "when every test passed on three assignments"
        case .dreamyFace: "by submitting two days early on three assignments"
        case .stitchedRing: "for a comeback on three assignments"
        case .lifeRing, .greenLightRing, .ouroborosRing, .functionRing, .binaryRing, .pulseRing:
            "when every test passed on a \(concept?.displayName.lowercased() ?? "concept") lab"
        }
    }

    /// The concept whose ring this item is; nil for every other item.
    public var concept: AssignmentConcept? {
        AssignmentConcept.allCases.first { WardrobeItem(concept: $0) == self }
    }

    /// The item for `concept`'s ring.
    public init(concept: AssignmentConcept) {
        switch concept {
        case .numbers: self = .lifeRing
        case .conditionals: self = .greenLightRing
        case .loops: self = .ouroborosRing
        case .functions: self = .functionRing
        case .binary: self = .binaryRing
        case .healthData: self = .pulseRing
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
        for concept in progress.fullMarksConcepts { items.insert(WardrobeItem(concept: concept)) }
        return items
    }
}
