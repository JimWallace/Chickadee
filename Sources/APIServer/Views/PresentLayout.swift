// APIServer/Views/PresentLayout.swift
//
// The document shell of a page for a projector. It is dark whatever the viewer
// prefers, and it has no site chrome: no nav, no course tabs, no flash banners
// and no session scripts. Present mode (`LeaderboardPresentPage`) is its one
// page. A page for the site uses `BaseLayout` instead.

import Elementary

struct PresentLayout<Content: HTML>: HTML {
    let title: String
    let page: PageRequestContext
    // Not `content`: see `BaseLayout`.
    let pageContent: Content

    init(title: String, page: PageRequestContext, @HTMLBuilder content: () -> Content) {
        self.title = title
        self.page = page
        self.pageContent = content()
    }

    var body: some HTML {
        Doctype()
        html(.lang("en"), .data("theme", value: "dark")) {
            head {
                meta(.charset(.utf8))
                meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
                meta(.name("color-scheme"), .content("dark"))
                meta(.name("app-version"), .content(page.appVersion))
                // The projector arena posts match results (tournament-arena.js).
                meta(.name("csrf-token"), .content(page.csrfToken))
                Elementary.title { "\(title) — Chickadee" }
                // The house bird, never the viewer's: this page is on a projector.
                TabIcons(page: page, key: AvatarIconKey.house)
                link(.rel(.stylesheet), .href(page.asset("/styles.css")))
                script(.src(page.asset("/chickadee-ui.js"))) {}
                script(.src(page.asset("/relative-time.js"))) {}
            }
            Elementary.body {
                pageContent
                script(.src(page.asset("/app.js"))) {}
                script(.src(page.asset("/table-poll.js"))) {}
            }
        }
    }
}
