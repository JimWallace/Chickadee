// Core/AvatarMarkup.swift
//
// What a view needs in order to draw an AvatarSpec.
//
// Holds NO geometry, NO colour and NO markup: the paths live once in
// Resources/Sprites/avatar-sprite.svg, the hex values live once in
// Public/styles.css, and the element is assembled once in
// Sources/APIServer/Views/Avatar.swift.  This file only names things.
//
// It emits TOKEN NAMES rather than a finished style attribute for a specific
// reason.  check-styles.sh permits an inline style only when every declaration
// is a custom-property assignment, and it reads the template statically — so a
// template writing style="#(someBlob)" fails, correctly, since the guard cannot
// see what the blob contains.  Handing the partial the token names lets it
// write real `--av-*:` declarations that the guard can check, without either
// side holding a second copy of the palette.  The alternative — building the
// whole element here and rendering it raw — would need an unsafe-HTML escape
// hatch this codebase does not use anywhere, and would hide the style
// attribute from the guard entirely.

/// Which of the sizes in the stylesheet a rendering wants.
public enum AvatarSize: String, CaseIterable, Sendable {
    /// 3rem — the account page.
    case standard
    /// 1.5rem — dense tables.  Beak, bib and wing marks stop being separable
    /// around here, which is why a leaderboard names a student by their handle
    /// and uses the bird for recognition rather than identification.
    case small
    /// 2.25rem — a roster row where the name beside the bird carries the
    /// identity (the instructor Students, Slip days and LEARN lists).  Inside
    /// the 32-48px band where the wing marks and expression still read.
    case roster
    /// 6rem — the leaderboard "you" card and the hill champion card, where one
    /// bird stands for one student.
    case hero
    /// 10rem — a Present-mode podium place, read across a room. The Present
    /// page alone scales it further (12rem first, 9.5rem second and third);
    /// see "Component vocabulary" in docs/ui-design.md.
    case podium

    public var cssClass: String {
        switch self {
        case .standard: "avatar"
        case .small: "avatar avatar-sm"
        case .roster: "avatar avatar-md"
        case .hero: "avatar avatar-lg"
        case .podium: "avatar avatar-xl"
        }
    }
}

/// How a rendering is announced.
///
/// Not a default, because the right answer depends entirely on what is beside
/// the bird, and getting it wrong is an accessibility defect in one of two
/// directions: a decorative image with a label is noise, and an identifying
/// image without one is an unlabelled row.
public enum AvatarAccessibility: Sendable, Equatable {
    /// A handle or name sits beside the bird and carries the identity.
    case decorative
    /// The bird stands alone and must announce whose it is — pass the handle.
    case labelled(String)
}

/// Everything the `Avatar` view needs, and nothing it does not.
public struct AvatarPresentation: Codable, Sendable, Equatable {
    /// Palette token names, e.g. "--avatar-slate-cap". The partial wraps each
    /// in `var(…)`. Six per colourway: cap, wing, body, bib, beak and mark.
    public let capToken: String
    public let wingToken: String
    /// The four tones that were fixed while every bird was a chickadee, now
    /// part of the colourway (docs/avatar-species.md, decision 3). The mark
    /// tone draws the wing marks and the brows.
    public let bodyToken: String
    public let bibToken: String
    public let beakToken: String
    public let markToken: String
    /// The colour an accessory is drawn in — part of the accessory axis, which
    /// is why the design writes it "8 + 5 accents".
    public let accentToken: String
    public let backdropToken: String
    /// The colour of a solid ring. For every other ring it is
    /// `--avatar-border-none`, which is transparent: the patterned rings and the
    /// staff ring colour themselves by class.
    public let borderToken: String
    /// The ring layer, e.g. "#av-ring-solid" or "#av-ring-staff". Never empty:
    /// no ring is "#av-ring-none".
    public let ringSymbolRef: String
    /// Fragment references for the symbols a spec varies, e.g.
    /// "#av-wing-barred" — WITH the leading marker, so the template never has
    /// to write one next to an interpolation. A template writing a literal
    /// marker immediately before an interpolation is a lexing shape that has
    /// cost this codebase before.
    public let tuftSymbolRef: String
    /// The species' plumage, e.g. "#av-plumage-robin".
    public let plumageSymbolRef: String
    public let wingSymbolRef: String
    public let expressionSymbolRef: String
    public let accessorySymbolRef: String
    /// The tilt as an SVG transform, e.g. "rotate(-9 32 34)", about the body
    /// centre. Always a value, never empty — upright is "rotate(0 32 34)" — so
    /// the template never has to test for one.
    public let tiltTransform: String
    /// "avatar" plus the size modifier, e.g. "avatar avatar-md".
    public private(set) var sizeClass: String
    /// The handle to announce; nil when the bird is decorative.
    public let label: String?

    /// `isStaff` draws the reserved staff ring in place of the chosen one. The
    /// caller decides it from the course role of the person drawn, for the course
    /// the page belongs to (or any course, on a page that belongs to none). There
    /// is no overload that defaults it: a surface that forgot the question
    /// compiled with a student ring on a staff bird (#1758), so every site says
    /// what it knows, and a students-only list says `false` with the reason.
    public init(
        for spec: AvatarSpec, size: AvatarSize, accessibility: AvatarAccessibility, isStaff: Bool
    ) {
        self.capToken = "--avatar-\(spec.cap.rawValue)-cap"
        self.wingToken = "--avatar-\(spec.cap.rawValue)-wing"
        self.bodyToken = "--avatar-\(spec.cap.rawValue)-body"
        self.bibToken = "--avatar-\(spec.cap.rawValue)-bib"
        self.beakToken = "--avatar-\(spec.cap.rawValue)-beak"
        self.markToken = "--avatar-\(spec.cap.rawValue)-mark"
        self.accentToken = "--avatar-accent-\(spec.accent.rawValue)"
        self.backdropToken = "--avatar-back-\(spec.backdrop.rawValue)"
        let ring = isStaff ? AvatarRing.staff : spec.border.ring
        self.ringSymbolRef = "#av-ring-\(ring.rawValue)"
        self.borderToken =
            (isStaff ? nil : spec.border.accent).map { "--avatar-accent-\($0.rawValue)" }
            ?? "--avatar-border-none"
        // A hat hides the tuft and the crest alike. Without a hat, a crested
        // species wears a crest in the shape its tuft slot maps to, and the
        // other species wear the tuft itself.
        let species = spec.species
        if spec.accessory.hidesTuft {
            self.tuftSymbolRef = "#av-tuft-none"
        } else if species.hasCrest {
            self.tuftSymbolRef = "#av-crest-\(species.rawValue)-\(AvatarCrestShape(tuft: spec.tuft).rawValue)"
        } else {
            self.tuftSymbolRef = "#av-tuft-\(spec.tuft.rawValue)"
        }
        self.plumageSymbolRef = "#av-plumage-\(species.rawValue)"
        // A species with its own art for this pattern draws that; the rest
        // draw the shared symbol.
        self.wingSymbolRef =
            species.wingArt.contains(spec.wing)
            ? "#av-wing-\(species.rawValue)-\(spec.wing.rawValue)"
            : "#av-wing-\(spec.wing.rawValue)"
        self.expressionSymbolRef = "#av-expression-\(spec.expression.rawValue)"
        self.accessorySymbolRef = "#av-accessory-\(spec.accessory.rawValue)"
        self.tiltTransform = "rotate(\(spec.tilt.degrees) 32 34)"
        self.sizeClass = size.cssClass
        switch accessibility {
        case .decorative: self.label = nil
        case .labelled(let name): self.label = name
        }
    }

    /// Every per-student custom property the `Avatar` view assigns, paired with
    /// the field it reads and the token it carries. The one list: `tokens`
    /// derives from it, and a test asserts each entry is assigned in
    /// both announce branches, so a token added here cannot reach the page
    /// unassigned, and a property assigned there cannot be absent here (#1761).
    public var inlineProperties: [AvatarInlineProperty] {
        [
            AvatarInlineProperty(name: "--av-cap", field: "capToken", token: capToken),
            AvatarInlineProperty(name: "--av-wing", field: "wingToken", token: wingToken),
            AvatarInlineProperty(name: "--av-body", field: "bodyToken", token: bodyToken),
            AvatarInlineProperty(name: "--av-bib", field: "bibToken", token: bibToken),
            AvatarInlineProperty(name: "--av-beak", field: "beakToken", token: beakToken),
            AvatarInlineProperty(name: "--av-mark", field: "markToken", token: markToken),
            AvatarInlineProperty(name: "--av-accent", field: "accentToken", token: accentToken),
            AvatarInlineProperty(name: "--av-backdrop", field: "backdropToken", token: backdropToken),
            AvatarInlineProperty(name: "--av-border", field: "borderToken", token: borderToken),
        ]
    }

    /// Every palette token this presentation names. The drift test asserts each
    /// is declared in the stylesheet, and that the stylesheet declares no
    /// avatar token no presentation can name.
    public var tokens: [String] { inlineProperties.map(\.token) }

    /// The same bird at another size. For a surface that shows a bird it was
    /// handed at one size, such as a bracket entrant on Present mode's winner
    /// card, and that has no spec to build it again.
    public func resized(to size: AvatarSize) -> AvatarPresentation {
        var copy = self
        copy.sizeClass = size.cssClass
        return copy
    }

    /// Every symbol this presentation names, in the order the partial stacks
    /// them — with the one that never varies. Seven, not one per feature: the
    /// body, cap, cheek, beak and bib of a species never vary, so they are
    /// baked into one plumage symbol per species. A slot is split out only
    /// when it varies. Tilt is not a layer; it is a transform on everything
    /// between the backdrop and the ring.
    public var layerRefs: [String] {
        [
            "#av-backdrop", tuftSymbolRef, plumageSymbolRef, wingSymbolRef, expressionSymbolRef,
            accessorySymbolRef, ringSymbolRef,
        ]
    }
}

/// One per-student custom property the avatar partial assigns: its `--av-*`
/// name, the `AvatarPresentation` field the partial reads it from, and the
/// palette token that field carries for this bird.
public struct AvatarInlineProperty: Sendable, Equatable {
    public let name: String
    public let field: String
    public let token: String
}
