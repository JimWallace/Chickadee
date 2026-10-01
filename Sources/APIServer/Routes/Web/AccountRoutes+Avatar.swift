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
        let isStaff =
            try await AvatarStore.courseStaff(among: [user.requireID()], on: req.db)
            .isEmpty == false
        let updated: AvatarSpec
        do {
            updated = try AvatarCustomization.applying(form.choices, to: current, isStaff: isStaff)
        } catch is AvatarCustomizationError {
            return req.redirect(to: "/account?avatar=invalid#chickadee")
        }
        user.avatarSpecJSON = AvatarStore.encode(updated)
        try await user.save(on: req.db)
        return req.redirect(to: "/account?avatar=saved#chickadee")
    }
}

/// The picker's two groups, built from `AvatarCustomization.options(for:)` so
/// the page cannot offer an option the chokepoint would refuse, and marking the
/// ones it would refuse as locked.
struct AvatarPickerContext: Encodable {
    let backdrops: [AvatarPickerOption]
    let borders: [AvatarPickerOption]
    /// Course staff wear the staff ring and cannot choose one: the Border group
    /// becomes a note.
    let isStaff: Bool
    /// The student's own colours, so a ring sample shows the ring they would
    /// wear: two-tone and stitched are drawn in their accent and cap colour.
    let backdropToken: String
    let accentToken: String
    let capToken: String

    init(for spec: AvatarSpec, isStaff: Bool) {
        let own = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative)
        self.isStaff = isStaff
        self.backdropToken = own.backdropToken
        self.accentToken = own.accentToken
        self.capToken = own.capToken
        backdrops = AvatarCustomization.options(for: .backdrop).map { value in
            AvatarPickerOption(
                value: value,
                label: value.capitalized,
                token: "--avatar-back-\(value)",
                ringRef: "",
                checked: value == spec.backdrop.rawValue,
                isNone: false,
                isLocked: false,
                season: "")
        }
        let season = TermSeason.current()
        borders = AvatarCustomization.options(for: .border).map { value in
            // The same token and ring the presentation would name for this
            // border, so the live preview draws exactly what a save would.
            var preview = spec
            preview.border = AvatarBorder(rawValue: value) ?? .none
            let drawn = AvatarPresentation(for: preview, size: .standard, accessibility: .decorative)
            // The ring a student already wears is never locked: a seasonal ring
            // is kept after its term, and a disabled radio would not be posted.
            let isWorn = value == spec.border.rawValue
            let isLocked = !isWorn && !AvatarCustomization.isOpen(value, for: .border, season: season)
            return AvatarPickerOption(
                value: value,
                label: Self.borderLabel(preview.border, isLocked: isLocked),
                token: drawn.borderToken,
                ringRef: drawn.ringSymbolRef,
                checked: isWorn,
                isNone: value == AvatarBorder.none.rawValue,
                isLocked: isLocked,
                season: preview.border.season?.rawValue ?? "")
        }
    }
}

extension AvatarPickerContext {
    /// A ring's name. A seasonal ring always names its term ("Maple (Fall)"),
    /// open or not, so the page reads the same on every date; any other
    /// locked ring says "locked".
    static func borderLabel(_ border: AvatarBorder, isLocked: Bool) -> String {
        if let season = border.season { return "\(border.displayName) (\(season.displayName))" }
        return isLocked ? "\(border.displayName) (locked)" : border.displayName
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
    /// The ring symbol this border draws, e.g. "#av-ring-rainbow"; empty for
    /// a backdrop. The live preview swaps the avatar's ring layer to it.
    let ringRef: String
    let checked: Bool
    /// The "no border" option, drawn as a dashed ring rather than a colour.
    let isNone: Bool
    /// An earned or special ring, or a seasonal ring out of its term: shown,
    /// but not selectable now.
    let isLocked: Bool
    /// The term of a seasonal ring ("fall"); empty for every other option.
    /// The visual-regression harness reads it to pin the one part of the page
    /// that changes with the date.
    let season: String
}
