// Core/AvatarCustomization.swift
//
// The one place a student's choice is applied to a stored AvatarSpec
// (docs/student-wardrobe.md, decision 3). A route never writes a spec field
// itself: it hands the raw form values here and stores what comes back.
//
// The species is drawn, not chosen (docs/avatar-species.md, decision 5, as
// superseded). A colourway is a shade WITHIN the student's own species, so only
// the colourways of that species are open: a colourway of another species
// would change the species, which only hatching a new bird may do. Every
// backdrop and every starter ring is open to every student, and a seasonal
// ring is open during its term. Earned and special rings exist and
// are shown locked: `applying` refuses them until unlocks arrive
// (docs/student-wardrobe.md, W3), and then only `isOpen` has to learn about a
// student's unlocks. Re-choosing the ring a student already wears is always
// allowed, so a seasonal ring is kept after its term. Course staff cannot
// change their ring.

/// A slot a student may change on the account page. `cap` is the colourway,
/// under its stored key: a shade of the student's own species.
public enum AvatarCustomizableSlot: String, CaseIterable, Sendable {
    case backdrop, border, cap
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
    /// The colourway belongs to another species. Only a hatch changes the
    /// species.
    case colourwayChangesSpecies(value: String)
}

public enum AvatarCustomization {

    /// The raw values a student of `species` may choose for `slot`, in display
    /// order. A colourway is open only within a species, so with no species
    /// the colourway slot offers nothing.
    public static func options(for slot: AvatarCustomizableSlot, species: AvatarSpecies? = nil) -> [String] {
        switch slot {
        case .backdrop: AvatarBackdrop.allCases.map(\.rawValue)
        case .border: AvatarBorder.allCases.map(\.rawValue)
        case .cap: species?.colourways.map(\.rawValue) ?? []
        }
    }

    /// Whether a student of `species` may choose `value` for `slot` during
    /// `season`. A colourway is open when it belongs to `species`; every
    /// backdrop is open; a ring is open when it is a starter ring, or a
    /// seasonal ring whose term is `season`.
    public static func isOpen(
        _ value: String, for slot: AvatarCustomizableSlot, species: AvatarSpecies? = nil,
        season: TermSeason = .current()
    ) -> Bool {
        switch slot {
        case .backdrop:
            return AvatarBackdrop(rawValue: value) != nil
        case .cap:
            guard let cap = AvatarCap(rawValue: value) else { return false }
            return AvatarSpecies.of(cap) == species
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
    /// chosen colourway belongs to another species than `spec`'s, a chosen
    /// ring is locked during `season` (other than the ring the student
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
            case .cap:
                guard let cap = AvatarCap(rawValue: value) else {
                    throw AvatarCustomizationError.unknownOption(slot: slot, value: value)
                }
                guard isOpen(value, for: .cap, species: spec.species) else {
                    throw AvatarCustomizationError.colourwayChangesSpecies(value: value)
                }
                updated.cap = cap
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
