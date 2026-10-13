// APIServer/Views/Pages/ErrorPage.swift
//
// The branded error page ErrorPageMiddleware renders for every browser route
// that throws. It reads nothing from disk and cannot throw, so it still
// renders when the rest of the app is broken.

import Elementary

struct ErrorPage: HTML {
    let page: PageRequestContext
    /// The HTTP status code, shown as the large glyph.
    let status: Int
    let title: String
    let message: String

    private var birdImage: String {
        if status == 404 { return "/images/chickadee-404.png" }
        if status > 499 { return "/images/chickadee-500.png" }
        return "/images/chickadee-icon-alt.png"
    }

    var body: some HTML {
        BaseLayout(title: title, page: page) {
            div(.class("error-page")) {
                img(.class("error-bird"), .src(page.asset(birdImage)), .alt(""))
                div(.class("error-code")) { String(status) }
                h1(.class("error-title")) { title }
                p(.class("error-message")) { message }
                a(.href("/"), .class("btn")) { "Go home" }
            }
            PageStyle(
                """
                .error-page {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    text-align: center;
                    padding: 5rem 1.5rem;
                    gap: 1rem;
                }
                .error-bird {
                    width: 5.5rem;
                    height: 5.5rem;
                    opacity: .8;
                    margin-bottom: .25rem;
                }
                .error-code {
                    font-size: 5em;  /* display glyph — 5x body size */
                    font-weight: 700;
                    line-height: 1;
                    /* gray-500, not lighter: the glyph is text to axe, and gray-300 on the
                       page background fails even the large-text contrast threshold. */
                    color: var(--gray-500);
                    letter-spacing: -.05em;
                }
                .error-title {
                    margin: 0;
                    font-size: var(--text-2xl);
                }
                """
            )
        }
    }
}
