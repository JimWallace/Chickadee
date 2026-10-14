// APIServer/Routes/Web/AccountRoutes+Avatar.swift
//
// The student's own bird choices (docs/student-wardrobe.md, W1, and
// docs/avatar-species.md, A2).
//
//   POST /account/avatar   → apply colourway / backdrop / border → redirect to /account
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
        /// The colourway, which decides the species.
        var cap: String?

        var choices: [String: String] {
            var choices: [String: String] = [:]
            choices[AvatarCustomizableSlot.backdrop.rawValue] = backdrop
            choices[AvatarCustomizableSlot.border.rawValue] = border
            choices[AvatarCustomizableSlot.cap.rawValue] = cap
            return choices
        }
    }

    @Sendable
    func saveAvatar(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(AvatarChoiceForm.self)

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

/// The picker's three groups, built from `AvatarCustomization.options(for:)` so
/// the page cannot offer an option the chokepoint would refuse, and marking the
/// ones it would refuse as locked.
struct AvatarPickerContext: Encodable {
    /// The colourways, grouped by the species each belongs to, in
    /// `AvatarSpecies` order. Each option is the student's own bird in that
    /// colourway, so the sample shows what a save would draw.
    let birds: [AvatarBirdGroup]
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
        let own = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: isStaff)
        self.isStaff = isStaff
        self.backdropToken = own.backdropToken
        self.accentToken = own.accentToken
        self.capToken = own.capToken
        let colourways = AvatarCustomization.options(for: .cap).compactMap(AvatarCap.init(rawValue:))
        birds = AvatarSpecies.allCases.map { species in
            AvatarBirdGroup(
                species: species.displayName,
                options: colourways.filter { AvatarSpecies.of($0) == species }.map { cap in
                    var preview = spec
                    preview.cap = cap
                    return AvatarBirdOption(
                        value: cap.rawValue,
                        label: cap.displayName,
                        checked: cap == spec.cap,
                        presentation: AvatarPresentation(
                            for: preview, size: .roster, accessibility: .decorative, isStaff: isStaff))
                })
        }
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
            // A sample is the ring a STUDENT would wear: staff never see the
            // samples, only the note, so the staff ring has no sample.
            let drawn = AvatarPresentation(
                for: preview, size: .standard, accessibility: .decorative, isStaff: false)
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

/// One species' row in the Species group.
struct AvatarBirdGroup: Encodable {
    let species: String
    let options: [AvatarBirdOption]
}

/// One colourway: the student's own bird drawn in it. The presentation
/// carries the six tone tokens, the plumage symbol and the tuft or crest the
/// live preview sets, so the preview draws exactly what a save would.
struct AvatarBirdOption: Encodable {
    let value: String
    let label: String
    let checked: Bool
    let presentation: AvatarPresentation
}

/// One swatch in the avatar picker.
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
