// APIServer/Views/HTMLAttribute+Chickadee.swift
//
// The attributes and elements Chickadee markup uses that Elementary does not
// ship: ARIA attributes, a valueless data flag, and the SVG `use` element.

import Elementary

extension HTMLAttribute where Tag: HTMLTrait.Attributes.Global {
    /// A valueless `data-` attribute, used as a behaviour hook.
    static func dataFlag(_ key: String) -> Self {
        HTMLAttribute(name: "data-\(key)", value: nil)
    }

    static func ariaLabel(_ value: String) -> Self {
        HTMLAttribute(name: "aria-label", value: value)
    }

    static var ariaHidden: Self {
        HTMLAttribute(name: "aria-hidden", value: "true")
    }

    static func ariaCurrent(_ value: String) -> Self {
        HTMLAttribute(name: "aria-current", value: value)
    }

    static func ariaExpanded(_ value: Bool) -> Self {
        HTMLAttribute(name: "aria-expanded", value: value ? "true" : "false")
    }

    static func ariaHasPopup(_ value: Bool) -> Self {
        HTMLAttribute(name: "aria-haspopup", value: value ? "true" : "false")
    }
}

extension HTMLTag {
    // Paired on purpose: in inline SVG an unclosed `<use>` would adopt the
    // elements after it as children. Upper-case, unlike Elementary's own
    // tags, because SwiftLint's `type_name` rule applies to this module.
    enum SVGUse: HTMLTrait.Paired { static let name = "use" }
}

extension HTMLTag.SVGUse: HTMLTrait.Attributes.href {}

typealias SVGUse<Content: HTML> = HTMLElement<HTMLTag.SVGUse, Content>
