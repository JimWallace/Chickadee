// APIServer/Routes/Web/AccountRoutes+Avatar.swift
//
// The student's own chickadee choices (docs/student-wardrobe.md, W1).
//
//   POST /account/avatar   → apply backdrop / border → redirect to /account
//
// The route never writes a spec field itself: it hands the raw form values to
// `AvatarCustomization`, the one chokepoint that later also checks unlocks.

import Core
import Fluent
import Vapor

extension AccountRoutes {

    /// The form. Every field is optional so a later form that changes only one
    /// slot needs no second route.
    struct AvatarChoiceForm: Content {
        var backdrop: String?
        var border: String?

        var choices: [String: String] {
            var choices: [String: String] = [:]
            choices[AvatarCustomizableSlot.backdrop.rawValue] = backdrop
            choices[AvatarCustomizableSlot.border.rawValue] = border
            return choices
        }
    }

    @Sendable
    func saveAvatar(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try req.content.decode(AvatarChoiceForm.self)

        let current = try await AvatarStore.ensureSpec(for: user, on: req.db)
        let updated: AvatarSpec
        do {
            updated = try AvatarCustomization.applying(form.choices, to: current)
        } catch is AvatarCustomizationError {
            return req.redirect(to: "/account?avatar=invalid#chickadee")
        }
        user.avatarSpecJSON = AvatarStore.encode(updated)
        try await user.save(on: req.db)
        return req.redirect(to: "/account?avatar=saved#chickadee")
    }
}

/// The picker's two groups, built from `AvatarCustomization.options(for:)` so
/// the page cannot offer an option the chokepoint would refuse.
struct AvatarPickerContext: Encodable {
    let backdrops: [AvatarPickerOption]
    let borders: [AvatarPickerOption]

    init(for spec: AvatarSpec) {
        backdrops = AvatarCustomization.options(for: .backdrop).map { value in
            AvatarPickerOption(
                value: value,
                label: value.capitalized,
                token: "--avatar-back-\(value)",
                checked: value == spec.backdrop.rawValue,
                isNone: false)
        }
        borders = AvatarCustomization.options(for: .border).map { value in
            // The same token the presentation would name for this border, so
            // the live preview draws exactly what a save would.
            var preview = spec
            preview.border = AvatarBorder(rawValue: value) ?? .none
            return AvatarPickerOption(
                value: value,
                label: value.capitalized,
                token: AvatarPresentation(for: preview, size: .standard, accessibility: .decorative)
                    .borderToken,
                checked: value == spec.border.rawValue,
                isNone: value == AvatarBorder.none.rawValue)
        }
    }
}

/// One swatch. Plain strings and Bools, because Leaf resolves no Swift
/// properties and treats a bare optional unreliably.
struct AvatarPickerOption: Encodable {
    let value: String
    let label: String
    /// A palette token name, e.g. "--avatar-back-sky". The live preview sets
    /// the avatar's custom property to it.
    let token: String
    let checked: Bool
    /// The "no border" option, drawn as a dashed ring rather than a colour.
    let isNone: Bool
}
