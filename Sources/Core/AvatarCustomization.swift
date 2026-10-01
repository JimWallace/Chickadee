// Core/AvatarCustomization.swift
//
// The one place a student's choice is applied to a stored AvatarSpec
// (docs/student-wardrobe.md, decision 3). A route never writes a spec field
// itself: it hands the raw form values here and stores what comes back.
//
// Every backdrop and every starter ring is open to every student, and a
// seasonal ring is open during its term. Earned and special rings exist and
// are shown locked: `applying` refuses them until unlocks arrive
// (docs/student-wardrobe.md, W3), and then only `isOpen` has to learn about a
// student's unlocks. Re-choosing the ring a student already wears is always
// allowed, so a seasonal ring is kept after its term. Course staff cannot
// change their ring.

/// A slot a student may change on the account page.
public enum AvatarCustomizableSlot: String, CaseIterable, Sendable {
    case backdrop, border
}

/// Why a choice was refused. The spec is never partly changed: a refused
/// request leaves every slot as it was.
public enum AvatarCustomizationError: Error, Equatable, Sendable {
    /// The request named a slot a student may not change.
    case slotNotCustomizable(String)
    /// The value is not an option of that slot.
    case unknownOption(slot: AvatarCustomizableSlot, value: String)
    /// The option exists but is not open to this student now: an earned or
    /// special ring before unlocks exist, or a seasonal ring out of its term.
    case optionLocked(slot: AvatarCustomizableSlot, value: String)
    /// Course staff wear the staff ring, which they cannot change.
    case staffRingIsFixed
}

public enum AvatarCustomization {

    /// The raw values a student may choose for `slot`, in display order.
    public static func options(for slot: AvatarCustomizableSlot) -> [String] {
        switch slot {
        case .backdrop: AvatarBackdrop.allCases.map(\.rawValue)
        case .border: AvatarBorder.allCases.map(\.rawValue)
        }
    }

    /// Whether a student may choose `value` for `slot` during `season`. Every
    /// backdrop is open; a ring is open when it is a starter ring, or a
    /// seasonal ring whose term is `season`.
    public static func isOpen(
        _ value: String, for slot: AvatarCustomizableSlot, season: TermSeason = .current()
    ) -> Bool {
        switch slot {
        case .backdrop:
            return AvatarBackdrop(rawValue: value) != nil
        case .border:
            guard let border = AvatarBorder(rawValue: value) else { return false }
            switch border.availability {
            case .starter: return true
            case .seasonal: return border.season == season
            case .earned, .special: return false
            }
        }
    }

    /// `spec` with each chosen slot set, keyed by slot raw value — for a
    /// student. See `applying(_:to:isStaff:)`.
    public static func applying(
        _ choices: [String: String], to spec: AvatarSpec
    ) throws
        -> AvatarSpec
    {
        try applying(choices, to: spec, isStaff: false)
    }

    /// `spec` with each chosen slot set, keyed by slot raw value. A slot not in
    /// `choices` is left as it is. Throws, and changes nothing, if any key is
    /// not a customizable slot, any value is not an option of its slot, a
    /// chosen ring is locked during `season` (other than the ring the student
    /// already wears), or `isStaff` and a ring was chosen at all.
    public static func applying(
        _ choices: [String: String], to spec: AvatarSpec, isStaff: Bool,
        season: TermSeason = .current()
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
            case .border:
                guard let border = AvatarBorder(rawValue: value) else {
                    throw AvatarCustomizationError.unknownOption(slot: slot, value: value)
                }
                if isStaff { throw AvatarCustomizationError.staffRingIsFixed }
                guard border == spec.border || isOpen(value, for: .border, season: season) else {
                    throw AvatarCustomizationError.optionLocked(slot: slot, value: value)
                }
                updated.border = border
            }
        }
        return updated
    }
}
