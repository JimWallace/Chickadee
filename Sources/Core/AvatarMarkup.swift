// Core/AvatarMarkup.swift
//
// What a Leaf template needs in order to draw an AvatarSpec.
//
// Holds NO geometry, NO colour and NO markup: the paths live once in
// Resources/Views/_avatar-sprite.leaf, the hex values live once in
// Public/styles.css, and the element is assembled once in
// Resources/Views/_avatar.leaf.  This file only names things.
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

/// Which of the two sizes in the stylesheet a rendering wants.
public enum AvatarSize: String, CaseIterable, Sendable {
    /// 3rem — the account page.
    case standard
    /// 1.5rem — dense tables.  Beak, bib and wing marks stop being separable
    /// around here, which is why a leaderboard names a student by their handle
    /// and uses the bird for recognition rather than identification.
    case small

    public var cssClass: String {
        switch self {
        case .standard: "avatar"
        case .small: "avatar avatar-sm"
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

/// Everything `_avatar.leaf` needs, and nothing it does not.
///
/// `Encodable` so it can be a Leaf sub-context; every field is a plain string
/// or bool because Leaf resolves no Swift properties (see the LeafKit note in
/// CLAUDE.md — `isEmpty` on an array silently resolves to nil, and a bare
/// optional in a conditional is worse).
public struct AvatarPresentation: Encodable, Sendable, Equatable {
    /// Palette token names, e.g. "--avatar-slate-cap". The partial wraps each
    /// in `var(…)`.
    public let capToken: String
    public let wingToken: String
    public let beakToken: String
    /// Serves both the cheeks and the marks on a patterned wing, so a pattern
    /// reads against any cap family without a slot of its own.
    public let cheekToken: String
    public let flankToken: String
    public let backdropToken: String
    /// The fragment reference for this spec's wing symbol, e.g.
    /// "#av-wing-barred" — WITH the leading marker, so the template never has
    /// to write one next to an interpolation. A template writing a literal
    /// marker immediately before an interpolation is exactly the Leaf lexing
    /// shape that has cost this codebase before; a bare unknown marker in text
    /// is inert, but one adjacent to a tag opening is not worth testing.
    public let wingSymbolRef: String
    /// "avatar" or "avatar avatar-sm".
    public let sizeClass: String
    /// Whether to announce the bird. An explicit Bool rather than testing the
    /// optional label in the template: Leaf's truthiness rules make a bare
    /// optional in a conditional unreliable.
    public let isLabelled: Bool
    /// The handle to announce; empty when decorative.
    public let label: String

    public init(for spec: AvatarSpec, size: AvatarSize, accessibility: AvatarAccessibility) {
        self.capToken = "--avatar-\(spec.cap.rawValue)-cap"
        self.wingToken = "--avatar-\(spec.cap.rawValue)-wing"
        self.beakToken = "--avatar-\(spec.cap.rawValue)-beak"
        self.cheekToken = "--avatar-cheek-\(spec.cheek.rawValue)"
        self.flankToken = "--avatar-flank-\(spec.flank.rawValue)"
        self.backdropToken = "--avatar-back-\(spec.backdrop.rawValue)"
        self.wingSymbolRef = "#av-wing-\(spec.wing.rawValue)"
        self.sizeClass = size.cssClass
        switch accessibility {
        case .decorative:
            self.isLabelled = false
            self.label = ""
        case .labelled(let name):
            self.isLabelled = true
            self.label = name
        }
    }

    /// Every palette token this presentation names. The drift test asserts each
    /// is declared in the stylesheet, and that the stylesheet declares no
    /// avatar token no presentation can name.
    public var tokens: [String] {
        [capToken, wingToken, beakToken, cheekToken, flankToken, backdropToken]
    }
}

public enum AvatarMarkup {
    /// The symbol ids stacked to draw `spec`, back to front.
    ///
    /// Five, not one per feature: the parts that never vary geometrically are
    /// baked into one plumage symbol. A slot is split out only when it varies.
    /// The partial hard-codes this order; this is what the drift test checks it
    /// against.
    public static func layerSymbolIDs(for spec: AvatarSpec) -> [String] {
        ["av-backdrop", "av-plumage", "av-wing-\(spec.wing.rawValue)", "av-beak", "av-eyes"]
    }
}
