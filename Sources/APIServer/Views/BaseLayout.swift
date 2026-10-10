// APIServer/Views/BaseLayout.swift
//
// The Elementary port of `base.leaf`: the document shell, the site chrome and
// the flash banners. The two must render the same markup while both exist.

import Elementary

/// The flash banners (`_flash.leaf`): the post-redirect one-shots and the
/// assignment editors' pre-redirect notice.
struct FlashMessages: Sendable {
    var success: String?
    var notice: String?
    var error: String?
}

struct BaseLayout<Content: HTML>: HTML {
    let title: String
    let page: PageRequestContext
    let flash: FlashMessages
    /// The page owns the viewport (`workbench.leaf`).
    let fullBleed: Bool
    /// Rendered inside a pane of the workbench or an LMS frame: no site chrome.
    let embedded: Bool
    /// Form POSTs re-render in place instead of navigating.
    let inPlaceForms: Bool
    // Not `content`: Elementary's `HTML` protocol still declares a deprecated
    // `content` requirement, and a stored property of that name satisfies it
    // and silently replaces the builder `body`.
    let pageContent: Content

    init(
        title: String,
        page: PageRequestContext,
        flash: FlashMessages = FlashMessages(),
        fullBleed: Bool = false,
        embedded: Bool = false,
        inPlaceForms: Bool = false,
        @HTMLBuilder content: () -> Content
    ) {
        self.title = title
        self.page = page
        self.flash = flash
        self.fullBleed = fullBleed
        self.embedded = embedded
        self.inPlaceForms = inPlaceForms
        self.pageContent = content()
    }

    var body: some HTML {
        HTMLRaw("<!DOCTYPE html>")
        html(.lang("en")) {
            documentHead
            Elementary.body {
                HTMLRaw(page.iconSprite)
                if !embedded {
                    a(.class("skip-link"), .href("#main-content")) { "Skip to main content" }
                    SiteNav(page: page)
                    div(.class("colour-bar"), .ariaHidden) {
                        div {}
                        div {}
                        div {}
                    }
                    if let user = page.currentUser, user.showCourseTabs {
                        CourseTabs(user: user, csrfToken: page.csrfToken)
                    }
                }
                main(.class("main"), .id("main-content")) {
                    FlashBanners(flash: flash)
                    pageContent
                }
                .attributes(.class("main-fullbleed"), when: fullBleed)
                footerScripts
            }
            .attributes(.class("page-fullbleed"), when: fullBleed)
        }
    }

    private var documentHead: some HTML {
        head {
            meta(.charset(.utf8))
            meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
            meta(.name("color-scheme"), .content("light dark"))
            meta(.name("csrf-token"), .content(page.csrfToken))
            meta(.name("app-version"), .content(page.appVersion))
            if page.currentUser != nil {
                meta(.name("session-idle-timeout-seconds"), .content(String(page.sessionIdleTimeoutSeconds)))
                meta(.name("session-idle-warning-seconds"), .content(String(page.sessionIdleWarningSeconds)))
            }
            Elementary.title { "\(title) — Chickadee" }
            // Elementary models neither `sizes` nor `type` on a link.
            for size in ["32x32", "16x16"] {
                link(
                    .rel(.icon), .href(page.asset("/favicon.png")),
                    .custom(name: "sizes", value: size), .custom(name: "type", value: "image/png"))
            }
            link(.rel("shortcut icon"), .href(page.asset("/favicon.png")), .custom(name: "type", value: "image/png"))
            link(.rel("apple-touch-icon"), .href(page.asset("/apple-touch-icon.png")))
            link(.rel(.stylesheet), .href(page.asset("/styles.css")))
            // Loaded in the head, not beside app.js: page scripts that run
            // during parse reference ChickadeeUI and its delegates.
            script(.src(page.asset("/chickadee-ui.js"))) {}
            script(.src(page.asset("/sparkline.js"))) {}
            script(.src(page.asset("/accordion-row.js"))) {}
            script(.src(page.asset("/surface-swap.js"))) {}
            script(.src(page.asset("/relative-time.js"))) {}
        }
    }

    @HTMLBuilder private var footerScripts: some HTML {
        script(.src(page.asset("/app.js"))) {}
        if page.currentUser != nil {
            script(.src(page.asset("/idle-logout.js"))) {}
            if inPlaceForms {
                // Before the multipart interceptor, which defers to it via
                // `defaultPrevented`.
                script(.src(page.asset("/inplace-forms.js"))) {}
            }
        }
        script(.src(page.asset("/multipart-forms.js"))) {}
    }
}

struct FlashBanners: HTML {
    let flash: FlashMessages

    var body: some HTML {
        if let success = flash.success {
            div(.class("flash flash-success"), .role("status")) { success }
        }
        if let notice = flash.notice {
            div(.class("flash flash-success"), .role("status")) { notice }
        }
        if let error = flash.error {
            div(.class("flash flash-error"), .role("alert")) { error }
        }
    }
}
