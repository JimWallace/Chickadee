// APIServer/Views/Pages/ErrorPage.swift
//
// The branded error page ErrorPageMiddleware renders for every browser route
// that throws. It reads nothing from disk and cannot throw, so it still
// renders when the rest of the app is broken.

import Elementary

struct ErrorPage: HTML {
    let page: PageRequestContext
    /// The HTTP status code, shown as fine print under the message.
    let status: Int
    /// A plain-language title (`errorPageTitle(for:)`), not the reason phrase.
    let title: String
    let message: String
    /// The same-origin page the reader came from, for "Go back"; nil when
    /// there is none to trust (#3007, finding 6).
    var backURL: String?

    private var birdImage: String {
        if status == 404 { return "/images/chickadee-404.png" }
        if status > 499 { return "/images/chickadee-500.png" }
        return "/images/chickadee-icon-alt.png"
    }

    var body: some HTML {
        BaseLayout(title: title, page: page) {
            div(.class("error-page")) {
                img(.class("error-bird"), .src(page.asset(birdImage)), .alt(""))
                h1(.class("error-title")) { title }
                p(.class("error-message")) { message }
                p(.class("card-meta")) { "Error \(status)" }
                div(.class("toolbar")) {
                    if let backURL {
                        a(.href(backURL), .class("btn")) { "Go back" }
                    }
                    a(.href("/"), .class("btn")) { "Go home" }
                }
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
                .error-title {
                    margin: 0;
                    font-size: var(--text-2xl);
                }
                """
            )
        }
    }
}
