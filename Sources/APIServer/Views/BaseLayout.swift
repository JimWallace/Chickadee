// APIServer/Views/BaseLayout.swift
//
// The document shell, the site chrome and the flash banners.

import Elementary

/// The flash banners: the post-redirect one-shots and the
/// assignment editors' pre-redirect notice.
/// The one-shot messages the layout shows above the page. An empty string
/// counts as no message, so a bare `?ok=` in a redirect draws no empty banner.
struct FlashMessages: Sendable {
    var success: String?
    var notice: String?
    var error: String?

    init(success: String? = nil, notice: String? = nil, error: String? = nil) {
        self.success = success.flatMap { $0.isEmpty ? nil : $0 }
        self.notice = notice.flatMap { $0.isEmpty ? nil : $0 }
        self.error = error.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct BaseLayout<Content: HTML>: HTML {
    let title: String
    let page: PageRequestContext
    let flash: FlashMessages
    /// The page owns the viewport (`WorkbenchPage`).
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
        Doctype()
        html(.lang("en")) {
            documentHead
            Elementary.body {
                HTMLRaw(page.iconSprite)
                // Every signed-in page can show a bird: the nav's account menu
                // shows the user's own. Once here, so no page inlines it again.
                if page.currentUser != nil {
                    AvatarSprite(page: page)
                }
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
            TabIcons(page: page, key: tabIconKey)
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

    /// The viewer's own bird, or the house bird when there is none. A staff
    /// member who opens a student's work still sees their own. An LMS frame
    /// shows the house bird, because nobody sees its tab.
    private var tabIconKey: String {
        if embedded { return AvatarIconKey.house }
        return page.currentUser?.tabIconKey ?? AvatarIconKey.house
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
            FlashBanner(.success) { success }
        }
        if let notice = flash.notice {
            FlashBanner(.success) { notice }
        }
        if let error = flash.error {
            FlashBanner(.error, role: "alert") { error }
        }
    }
}

/// One banner. The layout renders the one-shot flash messages with it. A page
/// uses it for a static state banner (`.warning`, `.neutral`), or for a
/// success or error banner that shows on every load or carries more than text
/// (the minted MCP token).
/// The flash classes are written here and nowhere else
/// (SwiftLint `elementary_flash_only_in_layout`).
struct FlashBanner<Content: HTML>: HTML {
    enum Kind: String {
        case success = "flash flash-success"
        case error = "flash flash-error"
        /// A static state banner: something about the page is off.
        case warning = "flash flash-warning"
        /// A static state banner with nothing wrong.
        case neutral = "flash flash-neutral"
    }

    let kind: Kind
    let role: MarkupAttributeValue.Role
    let content: Content

    init(_ kind: Kind, role: MarkupAttributeValue.Role = "status", @HTMLBuilder content: () -> Content) {
        self.kind = kind
        self.role = role
        self.content = content()
    }

    /// A `div`, so a page can add an `id` or `hidden` for a banner its
    /// script toggles.
    var body: some HTML<HTMLTag.div> {
        div(.class(kind.rawValue), .role(role)) { content }
    }
}

/// The HTML5 doctype. Elementary has no element for it, so it is the one raw
/// string every document starts with; `BaseLayout` and `PresentLayout` share it.
struct Doctype: HTML {
    var body: some HTML {
        HTMLRaw("<!DOCTYPE html>")
    }
}
