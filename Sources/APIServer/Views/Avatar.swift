// APIServer/Views/Avatar.swift
//
// One generated student chickadee, the Elementary port of `_avatar.leaf`. It
// draws from an `AvatarPresentation` (Core/AvatarMarkup.swift), which carries
// palette token names and symbol references, never colours or path data.
//
// The symbols live in the avatar sprite. A page that shows a bird must also
// render `AvatarSprite` once, or the bird is an empty circle and nothing fails.
//
// The style attribute holds custom-property assignments and nothing else, the
// one inline style the UI rules allow. The labelled bird announces whose it
// is; the decorative one is hidden, because the text beside it names the
// person. Keep this in step with `_avatar.leaf` while both exist.

import Core
import Elementary

struct Avatar: HTML {
    let avatar: AvatarPresentation

    /// Written as a custom attribute because SwiftLint bans the style
    /// modifier in views. It holds only custom properties, which the
    /// rendered-page guard allows.
    private var customProperties: String {
        "--av-cap: var(\(avatar.capToken)); --av-wing: var(\(avatar.wingToken)); "
            + "--av-accent: var(\(avatar.accentToken)); --av-backdrop: var(\(avatar.backdropToken)); "
            + "--av-border: var(\(avatar.borderToken))"
    }

    var body: some HTML {
        if avatar.isLabelled {
            SVG.svg(
                .class(avatar.sizeClass), .custom(name: "viewBox", value: "0 0 64 64"),
                .custom(name: "role", value: "img"),
                .ariaLabel(avatar.label), .custom(name: "style", value: customProperties)
            ) {
                parts
            }
        } else {
            SVG.svg(
                .class(avatar.sizeClass), .custom(name: "viewBox", value: "0 0 64 64"), .ariaHidden,
                .custom(name: "style", value: customProperties)
            ) {
                parts
            }
        }
    }

    /// The whole bird, back to front. The backdrop and the ring stay outside
    /// the tilt group, so the disc never turns.
    @HTMLBuilder private var parts: some SVGContent {
        SVG.use(.href("#av-backdrop")) {}
        SVG.g(.transform(avatar.tiltTransform)) {
            SVG.use(.href(avatar.tuftSymbolRef)) {}
            SVG.use(.href("#av-plumage")) {}
            SVG.use(.href(avatar.wingSymbolRef)) {}
            SVG.use(.href(avatar.expressionSymbolRef)) {}
            SVG.use(.href(avatar.accessorySymbolRef)) {}
        }
        SVG.use(.href(avatar.ringSymbolRef), .dataFlag("av-ring")) {}
    }
}
