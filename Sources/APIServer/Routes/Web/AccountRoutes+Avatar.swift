// APIServer/Routes/Web/AccountRoutes+Avatar.swift
//
// The student's own bird choices (docs/student-wardrobe.md, W1, and
// docs/avatar-species.md, A2).
//
//   POST /account/avatar           → apply expression / backdrop / border → redirect to /account,
//                                    or a bare status when the request accepts JSON (the
//                                    result page's Earned toast saves in place)
//   POST /account/avatar/hatch     → hatch a new bird of another species → ?avatar=hatched#bird,
//                                    or ?avatar=nohatch#bird when none is left this term
//   POST /account/avatar/restore   → go back to the bird before the last hatch → ?avatar=restored#bird
//
// `GET /account?hatch=confirm#bird` shows the hatch confirm with no script.
//
// The species and the colourway come with the bird: only a hatch changes
// them. A student chooses the bird's face (#2588).
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
        /// The bird's face.
        var expression: String?

        var choices: [String: String] {
            var choices: [String: String] = [:]
            choices[AvatarCustomizableSlot.backdrop.rawValue] = backdrop
            choices[AvatarCustomizableSlot.border.rawValue] = border
            choices[AvatarCustomizableSlot.expression.rawValue] = expression
            return choices
        }
    }

    @Sendable
    func saveAvatar(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(AvatarChoiceForm.self)
        // The Earned toast's Wear it (docs/result-celebration.md, J2) asks
        // for JSON, and updates the page bird itself instead of following a
        // redirect to this page.
        let inPlace = req.headers[.accept].contains { $0.contains("application/json") }

        let current = try await AvatarStore.ensureSpec(for: user, on: req.db)
        let isStaff =
            try await AvatarStore.courseStaff(among: [user.requireID()], on: req.db)
            .isEmpty == false
        let updated: AvatarSpec
        do {
            updated = try AvatarCustomization.applying(
                form.choices, to: current, isStaff: isStaff,
                unlocked: try await WardrobeUnlockStore.unlocked(for: user.requireID(), on: req.db))
        } catch is AvatarCustomizationError {
            return inPlace
                ? Response(status: .unprocessableEntity) : req.redirect(to: "/account?avatar=invalid#chickadee")
        }
        user.avatarSpecJSON = AvatarStore.encode(updated)
        try await user.save(on: req.db)
        return inPlace ? Response(status: .noContent) : req.redirect(to: "/account?avatar=saved#chickadee")
    }

    /// Draws a bird of another species. The backdrop, the ring and the class
    /// handles stay; the current bird is kept as the previous one.
    @Sendable
    func hatchAvatar(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let term = AcademicTerm.current() else {
            throw AppError.internalFailure(reason: "The current academic term could not be determined.")
        }
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

/// The "Your bird" card: the bird itself, and the Face, Backdrop and Ring
/// groups, built from `AvatarCustomization.options(for:)` so the page cannot
/// offer an option the chokepoint would refuse. A face or ring that a student
/// earns is not shown until it is earned: items are surprises, and a list of
/// items not earned yet reads as a list of failures (docs/student-wardrobe.md,
/// E1 to E3). The one exception is a seasonal ring out of its term, which
/// every student gets: it is listed apart, as "Not open yet".
struct AvatarPickerContext: Encodable {
    /// The student's bird at the podium size, the card's hero and the live
    /// preview's target.
    let hero: AvatarPresentation
    /// The bird's handle, "Curious Noether": its name in every course. Empty
    /// for a bird with none (course staff), which hides the line.
    let handle: String
    /// "Cardinal".
    let speciesName: String
    /// "Hatched Sep 8, 2026"; empty hides the line.
    let hatchedText: String
    /// The hatch control and strip; nil shows neither.
    let hatch: AvatarHatchContext?
    /// The faces a student may choose now, each the student's own bird with
    /// that face, so the sample shows what a save would draw. The worn face
    /// is always among them.
    let faces: [AvatarBirdOption]
    let backdrops: [AvatarPickerOption]
    /// The rings a student may choose now, the worn one always among them.
    let rings: [AvatarPickerOption]
    /// The seasonal rings out of their term: shown, never selectable.
    let laterRings: [AvatarPickerOption]
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
        hatch: AvatarHatchContext? = nil, unlocked: Set<WardrobeItem> = []
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
        faces = AvatarCustomization.options(for: .expression).compactMap(AvatarExpression.init(rawValue:))
            // The worn face is always open.
            .filter { expression in
                expression == spec.expression
                    || AvatarCustomization.isOpen(expression.rawValue, for: .expression, unlocked: unlocked)
            }
            .map { expression in
                var preview = spec
                preview.expression = expression
                return AvatarBirdOption(
                    value: expression.rawValue,
                    label: expression.displayName,
                    checked: expression == spec.expression,
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
                season: "")
        }
        let season = TermSeason.current()
        // The ring a student already wears is always open: a seasonal ring is
        // kept after its term.
        let values = AvatarCustomization.options(for: .border)
        let open = values.filter { value in
            value == spec.border.rawValue
                || AvatarCustomization.isOpen(value, for: .border, season: season, unlocked: unlocked)
        }
        rings = open.map { Self.ringOption($0, for: spec, isLocked: false) }
        laterRings = values.filter { !open.contains($0) && AvatarBorder(rawValue: $0)?.season != nil }
            .map { Self.ringOption($0, for: spec, isLocked: true) }
    }
}

extension AvatarPickerContext {
    /// One ring swatch: the same token and ring the presentation would name
    /// for this border, so the live preview draws exactly what a save would.
    private static func ringOption(_ value: String, for spec: AvatarSpec, isLocked: Bool) -> AvatarPickerOption {
        var preview = spec
        preview.border = AvatarBorder(rawValue: value) ?? .none
        // A sample is the ring a STUDENT would wear: staff never see the
        // samples, only the note, so the staff ring has no sample.
        let drawn = AvatarPresentation(for: preview, size: .standard, accessibility: .decorative, isStaff: false)
        return AvatarPickerOption(
            value: value,
            label: borderLabel(preview.border, isLocked: isLocked),
            token: drawn.borderToken,
            ringRef: drawn.ringSymbolRef,
            checked: value == spec.border.rawValue,
            isNone: value == AvatarBorder.none.rawValue,
            season: preview.border.season?.rawValue ?? "")
    }

    /// A ring's name. A seasonal ring is named by its term: "Fall" among the
    /// open rings, "Winter · opens in January" under "Not open yet". No other
    /// ring is ever shown locked.
    static func borderLabel(_ border: AvatarBorder, isLocked: Bool) -> String {
        guard isLocked, let season = border.season else { return border.displayName }
        return "\(season.displayName) · opens in \(season.startMonthName)"
    }
}

/// One face: the student's own bird drawn with it. The presentation carries
/// the expression symbol the live preview sets, so the preview draws exactly
/// what a save would.
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
    /// The term of a seasonal ring ("fall"); empty for every other option.
    /// The visual-regression harness reads it to pin the one part of the page
    /// that changes with the date.
    let season: String
}
