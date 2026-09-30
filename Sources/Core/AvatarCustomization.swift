// Core/AvatarCustomization.swift
//
// The one place a student's choice is applied to a stored AvatarSpec
// (docs/student-wardrobe.md, decision 3). A route never writes a spec field
// itself: it hands the raw form values here and stores what comes back.
//
// Today every option of the two customizable slots is open to every student.
// When unlocks arrive, `options(for:)` narrows and `applying(_:to:)` refuses a
// locked option; nothing else has to change.

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
}

public enum AvatarCustomization {

    /// The raw values a student may choose for `slot`, in display order.
    public static func options(for slot: AvatarCustomizableSlot) -> [String] {
        switch slot {
        case .backdrop: AvatarBackdrop.allCases.map(\.rawValue)
        case .border: AvatarBorder.allCases.map(\.rawValue)
        }
    }

    /// `spec` with each chosen slot set, keyed by slot raw value. A slot not in
    /// `choices` is left as it is. Throws, and changes nothing, if any key is
    /// not a customizable slot or any value is not an option of its slot.
    public static func applying(
        _ choices: [String: String], to spec: AvatarSpec
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
                updated.border = border
            }
        }
        return updated
    }
}
