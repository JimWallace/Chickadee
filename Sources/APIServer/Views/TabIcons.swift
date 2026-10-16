// APIServer/Views/TabIcons.swift
//
// The icon links in the document head.

import Elementary

/// The tab icons (docs/student-avatars.md, "The tab icon"): the house bird as
/// an ICO for a browser without SVG favicons, the bird that `key` names as
/// SVG, and the house bird for the home screen. `BaseLayout` and
/// `PresentLayout` share it.
struct TabIcons: HTML {
    let page: PageRequestContext
    let key: String

    var body: some HTML {
        // Elementary models neither `sizes` nor `type` on a link.
        link(.rel(.icon), .href(page.asset("/favicon.ico")), .custom(name: "sizes", value: "32x32"))
        link(
            .rel(.icon), .custom(name: "type", value: "image/svg+xml"),
            .href(AvatarIconKey.path(version: page.appVersion, key: key)))
        link(.rel("apple-touch-icon"), .href(page.asset("/apple-touch-icon.png")))
    }
}
