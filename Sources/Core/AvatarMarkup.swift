// Core/AvatarMarkup.swift
//
// Turning an AvatarSpec into markup.  Holds NO geometry and NO colour: the
// paths live once in Resources/Views/_avatar-sprite.leaf and the hex values
// live once in Public/styles.css, and this file names them.  That is the whole
// design — a second copy of either in Swift would be a second source of truth
// that drifts silently, since a wrong path still renders and a wrong hex is
// still a colour.

/// Which of the two sizes in the stylesheet a rendering wants.
public enum AvatarSize: String, CaseIterable, Sendable {
    /// 3rem — the account page.
    case standard
    /// 1.5rem — dense tables.  Beak, bib and wing marks stop being separable
    /// around here, which is why a leaderboard names a student by their handle
    /// and uses the bird for recognition rather than identification.
    case small

    var cssClass: String {
        switch self {
        case .standard: "avatar"
        case .small: "avatar avatar-sm"
        }
    }
}

/// How a rendering is announced.
///
/// Not a default, because the right answer depends entirely on what is beside
/// the bird and getting it wrong is an accessibility defect in one of two
/// directions: a decorative image with a label is noise, and an identifying
/// image without one is an unlabelled row.
public enum AvatarAccessibility: Sendable, Equatable {
    /// A handle or name sits beside the bird and carries the identity.
    case decorative
    /// The bird stands alone and must announce whose it is — pass the handle.
    case labelled(String)
}

public enum AvatarMarkup {

    /// The symbol ids stacked to draw `spec`, back to front.
    ///
    /// Five, not one per feature: the parts that never vary geometrically are
    /// baked into one plumage symbol.  A slot is split out only when it varies.
    public static func layerSymbolIDs(for spec: AvatarSpec) -> [String] {
        ["av-backdrop", "av-plumage", "av-wing-\(spec.wing.rawValue)", "av-beak", "av-eyes"]
    }

    /// The palette tokens `spec` selects, as `--av-*` custom-property
    /// assignments for the wrapping element.
    ///
    /// Assigning custom properties inline is the sanctioned form (a colour
    /// property or a literal is not), and it is what lets one sprite serve
    /// every bird: the shapes are shared, the assignment is per student.
    public static func customProperties(for spec: AvatarSpec) -> String {
        [
            "--av-cap: var(--avatar-\(spec.cap.rawValue)-cap)",
            "--av-wing: var(--avatar-\(spec.cap.rawValue)-wing)",
            "--av-beak: var(--avatar-\(spec.cap.rawValue)-beak)",
            "--av-cheek: var(--avatar-cheek-\(spec.cheek.rawValue))",
            "--av-wing-mark: var(--avatar-cheek-\(spec.cheek.rawValue))",
            "--av-flank: var(--avatar-flank-\(spec.flank.rawValue))",
            "--av-backdrop: var(--avatar-back-\(spec.backdrop.rawValue))",
        ].joined(separator: "; ")
    }

    /// One bird as an SVG element.
    ///
    /// - Important: this references the sprite by fragment, so the page must
    ///   also include the `_avatar-sprite.leaf` partial.  It is an SVG element
    ///   on a page, NOT a standalone image: it cannot be an `<img>` src, saved,
    ///   or emailed.  A standalone renderer is possible and is deliberately not
    ///   here — it would need the path data and the hex palette, and the only
    ///   version of it worth having reads both from the files that already own
    ///   them rather than re-holding them in Swift.
    public static func inlineSVG(
        for spec: AvatarSpec,
        size: AvatarSize = .standard,
        accessibility: AvatarAccessibility = .decorative
    ) -> String {
        let uses = layerSymbolIDs(for: spec)
            // Doubled pound delimiter: inside #"…"# the sequence `"#` in
            // `href="#` would terminate the literal at the fragment marker.
            .map { ##"<use href="#\##($0)"/>"## }
            .joined()
        let described: String =
            switch accessibility {
            case .decorative: #"aria-hidden="true""#
            case .labelled(let name): #"role="img" aria-label="\#(escaped(name))""#
            }
        return #"""
            <svg class="\#(size.cssClass)" style="\#(customProperties(for: spec))" \#
            viewBox="0 0 64 64" \#(described)>\#(uses)</svg>
            """#
    }

    /// Minimal attribute-value escaping for a handle placed in `aria-label`.
    /// Handles are generated from curated word lists, so this guards a shape
    /// the type allows rather than one the generator produces.
    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
