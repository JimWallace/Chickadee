// APIServer/Routes/Web/AccountRoutes+Avatar.swift
//
// The student's own bird choices (docs/student-wardrobe.md, W1, and
// docs/avatar-species.md, A2).
//
//   POST /account/avatar           → apply colourway / backdrop / border → redirect to /account
//   POST /account/avatar/hatch     → hatch a new bird of another species → ?avatar=hatched#bird,
//                                    or ?avatar=nohatch#bird when none is left this term
//   POST /account/avatar/restore   → go back to the bird before the last hatch → ?avatar=restored#bird
//
// `GET /account?hatch=confirm#bird` shows the hatch confirm with no script.
//
// A colourway is a shade within the student's own species. A colourway of
// another species is refused: only a hatch changes the species.
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
        /// The colourway: a shade of the student's own species.
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

    /// Draws a bird of another species. The backdrop, the ring and the class
    /// handles stay; the current bird is kept as the previous one.
    @Sendable
    func hatchAvatar(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let term = AcademicTerm.current() else { throw Abort(.internalServerError) }
        _ = try await AvatarStore.ensureSpec(for: user, on: req.db)
        let hatched = try await AvatarStore.hatch(for: user, term: term, on: req.db)
        return req.redirect(to: hatched ? "/account?avatar=hatched#bird" : "/account?avatar=nohatch#bird")
    }

    /// Puts the bird before the last hatch back. It does not give the hatch
    /// back. With no previous bird, it only returns to the card.
    @Sendable
    func restoreAvatar(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let restored = try await AvatarStore.restorePreviousBird(for: user, on: req.db)
        return req.redirect(to: restored ? "/account?avatar=restored#bird" : "/account#bird")
    }
}

/// The "Your bird" card: the bird itself, and the Colour and Ring groups,
/// built from `AvatarCustomization.options(for:species:)` so the page cannot
/// offer an option the chokepoint would refuse. A ring the chokepoint would
/// refuse is listed apart, as "Not open yet", and is not an input.
struct AvatarPickerContext: Encodable {
    /// The student's bird at the podium size, the card's hero and the live
    /// preview's target.
    let hero: AvatarPresentation
    /// The bird's handle, "Curious Noether": its name in every course. Empty
    /// for a bird with none (course staff), which hides the line.
    let handle: String
    /// "Cardinal".
    let speciesName: String
    /// "Three cardinal colourways, plus your backdrop."
    let colourNote: String
    /// "Hatched Sep 8, 2026"; empty hides the line.
    let hatchedText: String
    /// The hatch control and strip; nil shows neither.
    let hatch: AvatarHatchContext?
    /// The colourways of the student's own species, each the student's own
    /// bird in that colourway, so the sample shows what a save would draw.
    let feathers: [AvatarBirdOption]
    let backdrops: [AvatarPickerOption]
    /// The rings a student may choose now, the worn one always among them.
    let rings: [AvatarPickerOption]
    /// The rings that are not open yet: shown, never selectable.
    let lockedRings: [AvatarPickerOption]
    /// Course staff wear the staff ring and cannot choose one: the Ring group
    /// becomes a note.
    let isStaff: Bool
    /// The student's own colours, so a ring sample shows the ring they would
    /// wear: two-tone and stitched are drawn in their accent and cap colour.
    let backdropToken: String
    let accentToken: String
    let capToken: String

    init(
        for spec: AvatarSpec, isStaff: Bool, handle: String = "", hatchedText: String = "",
        hatch: AvatarHatchContext? = nil
    ) {
        hero = AvatarPresentation(for: spec, size: .podium, accessibility: .decorative, isStaff: isStaff)
        self.isStaff = isStaff
        self.handle = handle
        self.hatchedText = hatchedText
        self.hatch = hatch
        self.backdropToken = hero.backdropToken
        self.accentToken = hero.accentToken
        self.capToken = hero.capToken
        speciesName = spec.species.displayName
        let colourways = AvatarCustomization.options(for: .cap, species: spec.species)
            .compactMap(AvatarCap.init(rawValue:))
        colourNote =
            "\(Self.countWord(colourways.count)) \(spec.species.displayName.lowercased()) colourways, "
            + "plus your backdrop."
        feathers = colourways.map { cap in
            var preview = spec
            preview.cap = cap
            return AvatarBirdOption(
                value: cap.rawValue,
                label: cap.displayName,
                checked: cap == spec.cap,
                presentation: AvatarPresentation(
                    for: preview, size: .roster, accessibility: .decorative, isStaff: isStaff))
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
        let borders = AvatarCustomization.options(for: .border).map { value in
            // The same token and ring the presentation would name for this
            // border, so the live preview draws exactly what a save would.
            var preview = spec
            preview.border = AvatarBorder(rawValue: value) ?? .none
            // A sample is the ring a STUDENT would wear: staff never see the
            // samples, only the note, so the staff ring has no sample.
            let drawn = AvatarPresentation(
                for: preview, size: .standard, accessibility: .decorative, isStaff: false)
            // The ring a student already wears is never locked: a seasonal ring
            // is kept after its term.
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
        rings = borders.filter { !$0.isLocked }
        lockedRings = borders.filter(\.isLocked)
    }
}

extension AvatarPickerContext {
    /// A ring's name. A seasonal ring is named by its term: "Fall" among the
    /// open rings, "Winter · opens in January" under "Not open yet". Any
    /// other locked ring is earned: "Two-tone · earned".
    static func borderLabel(_ border: AvatarBorder, isLocked: Bool) -> String {
        guard isLocked else { return border.displayName }
        if let season = border.season { return "\(season.displayName) · opens in \(season.startMonthName)" }
        return "\(border.displayName) · earned"
    }

    /// "Eight", "Three": the colourway count as a word, as the note reads.
    static func countWord(_ count: Int) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return words.indices.contains(count) ? words[count] : "\(count)"
    }
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
