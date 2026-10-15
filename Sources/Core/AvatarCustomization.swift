// Core/AvatarCustomization.swift
//
// The one place a student's choice is applied to a stored AvatarSpec
// (docs/student-wardrobe.md, decision 3). A route never writes a spec field
// itself: it hands the raw form values here and stores what comes back.
//
// The species and the colourway are drawn, not chosen (docs/avatar-species.md,
// decision 5, as superseded twice): only hatching a new bird changes either. A
// student chooses the bird's face instead (#2588). Every starter expression,
// every backdrop and every starter ring is open to every student, and a
// seasonal ring is open during its term. An unlockable face or an earned
// ring opens when the student has earned it (`WardrobeItem`,
// docs/student-wardrobe.md, W3); until then, and for an item no rule earns
// yet, `applying` refuses it. Re-choosing the face or the ring a student
// already wears is always allowed, so a seasonal ring is kept after its term.
// Course staff cannot change their ring.

/// A slot a student may change on the account page.
public enum AvatarCustomizableSlot: String, CaseIterable, Sendable {
    case backdrop, border, expression
}

/// Why a choice was refused. The spec is never partly changed: a refused
/// request leaves every slot as it was.
public enum AvatarCustomizationError: Error, Equatable, Sendable {
    /// The request named a slot a student may not change.
    case slotNotCustomizable(String)
    /// The value is not an option of that slot.
    case unknownOption(slot: AvatarCustomizableSlot, value: String)
    /// The option exists but is not open to this student now: an unlockable
    /// expression or an earned or special ring before unlocks exist, or a
    /// seasonal ring out of its term.
    case optionLocked(slot: AvatarCustomizableSlot, value: String)
    /// Course staff wear the staff ring, which they cannot change.
    case staffRingIsFixed
}

public enum AvatarCustomization {

    /// The raw values of `slot`, in display order: every option, open or
    /// not. `isOpen` says which a student may choose now.
    public static func options(for slot: AvatarCustomizableSlot) -> [String] {
        switch slot {
        case .backdrop: AvatarBackdrop.allCases.map(\.rawValue)
        case .border: AvatarBorder.allCases.map(\.rawValue)
        case .expression: AvatarExpression.allCases.map(\.rawValue)
        }
    }

    /// Whether a student who has earned `unlocked` may choose `value` for
    /// `slot` during `season`. Every backdrop is open; an expression is open
    /// when it is a starter face; a ring is open when it is a starter ring, or
    /// a seasonal ring whose term is `season`. An earned item
    /// (`WardrobeItem`) is open to a student who has earned it.
    public static func isOpen(
        _ value: String, for slot: AvatarCustomizableSlot, season: TermSeason = .current(),
        unlocked: Set<WardrobeItem> = []
    ) -> Bool {
        if let item = WardrobeItem(slot: slot, value: value), unlocked.contains(item) { return true }
        switch slot {
        case .backdrop:
            return AvatarBackdrop(rawValue: value) != nil
        case .expression:
            guard let expression = AvatarExpression(rawValue: value) else { return false }
            return AvatarExpression.starterCases.contains(expression)
        case .border:
            guard let border = AvatarBorder(rawValue: value) else { return false }
            switch border.availability {
            case .starter: return true
            case .seasonal: return border.season == season
            case .earned, .special: return false
            }
        }
    }

    /// `spec` with each chosen slot set, keyed by slot raw value. A slot not in
    /// `choices` is left as it is. Throws, and changes nothing, if any key is
    /// not a customizable slot, any value is not an option of its slot, a
    /// chosen face or ring is locked during `season` for a student who has
    /// earned `unlocked` (other than the one the student already wears), or
    /// `isStaff` and a ring was chosen at all.
    public static func applying(
        _ choices: [String: String], to spec: AvatarSpec, isStaff: Bool,
        season: TermSeason = .current(), unlocked: Set<WardrobeItem> = []
    ) throws
        -> AvatarSpec
    {
        var updated = spec
        for (key, value) in choices.sorted(by: { $0.key < $1.key }) {
            guard let slot = AvatarCustomizableSlot(rawValue: key) else {
                throw AvatarCustomizationError.slotNotCustomizable(key)
            }
            switch slot {
            case .backdrop:
                guard let backdrop = AvatarBackdrop(rawValue: value) else {
                    throw AvatarCustomizationError.unknownOption(slot: slot, value: value)
                }
                updated.backdrop = backdrop
            case .expression:
                guard let expression = AvatarExpression(rawValue: value) else {
                    throw AvatarCustomizationError.unknownOption(slot: slot, value: value)
                }
                guard expression == spec.expression || isOpen(value, for: .expression, unlocked: unlocked) else {
                    throw AvatarCustomizationError.optionLocked(slot: slot, value: value)
                }
                updated.expression = expression
            case .border:
                guard let border = AvatarBorder(rawValue: value) else {
                    throw AvatarCustomizationError.unknownOption(slot: slot, value: value)
                }
                if isStaff { throw AvatarCustomizationError.staffRingIsFixed }
                guard border == spec.border || isOpen(value, for: .border, season: season, unlocked: unlocked) else {
                    throw AvatarCustomizationError.optionLocked(slot: slot, value: value)
                }
                updated.border = border
            }
        }
        return updated
    }
}
