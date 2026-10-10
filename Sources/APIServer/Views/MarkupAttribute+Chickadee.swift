// APIServer/Views/MarkupAttribute+Chickadee.swift
//
// The attributes Chickadee markup uses that Elementary does not ship: ARIA
// attributes and a valueless data flag. On `MarkupAttribute`, so they apply to
// HTML and SVG elements alike.

import Elementary

extension MarkupAttribute where Tag: MarkupTrait.AllowsAttributes {
    /// A valueless `data-` attribute, used as a behaviour hook.
    static func dataFlag(_ key: String) -> Self {
        MarkupAttribute(name: "data-\(key)", value: nil)
    }

    static func ariaLabel(_ value: String) -> Self {
        MarkupAttribute(name: "aria-label", value: value)
    }

    static var ariaHidden: Self {
        MarkupAttribute(name: "aria-hidden", value: "true")
    }

    static func ariaCurrent(_ value: String) -> Self {
        MarkupAttribute(name: "aria-current", value: value)
    }

    static func ariaExpanded(_ value: Bool) -> Self {
        MarkupAttribute(name: "aria-expanded", value: value ? "true" : "false")
    }

    static func ariaHasPopup(_ value: Bool) -> Self {
        MarkupAttribute(name: "aria-haspopup", value: value ? "true" : "false")
    }
}
