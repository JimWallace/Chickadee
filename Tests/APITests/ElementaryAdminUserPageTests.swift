import Elementary
import Testing

@testable import APIServer

/// The Elementary spike (docs/elementary-spike.md): the admin user page and the
/// base layout render as pure values, without an app, a database or a request.
@Suite struct ElementaryAdminUserPageTests {

    private let page = PageRequestContext(
        currentUser: nil,
        csrfToken: "salt-token",
        appVersion: "9.9.9",
        sessionIdleTimeoutSeconds: 0,
        sessionIdleWarningSeconds: 0,
        iconSprite: "<svg id=\"sprite\"></svg>"
    )

    private func render(
        displayName: String? = "Ada Lovelace",
        username: String = "ada",
        enrolled: [AdminCourseRef] = [],
        available: [AdminCourseRef] = []
    ) -> String {
        AdminUserPage(
            page: page, targetUserID: "U1", displayName: displayName, username: username, role: "user",
            enrolledCourses: enrolled, availableCourses: available
        ).render()
    }

    private let fall = AdminCourseRef(id: "C1", code: "CS135", name: "Design", termLabel: "Fall 2025")
    private let untermed = AdminCourseRef(id: "C2", code: "CS136", name: "Algorithms", termLabel: nil)

    @Test func theDocumentShellMatchesTheBaseLayout() {
        let html = render()
        #expect(html.hasPrefix("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">"))
        #expect(html.contains("<title>Courses — Ada Lovelace — Chickadee</title>"))
        #expect(html.contains("<meta name=\"csrf-token\" content=\"salt-token\">"))
        #expect(html.contains("<link rel=\"stylesheet\" href=\"/styles.css?v=9.9.9\">"))
        #expect(html.contains("<svg id=\"sprite\"></svg>"))
        #expect(html.contains("<main class=\"main\" id=\"main-content\">"))
    }

    @Test func aLoggedOutPageOffersLogInAndNoIdleTimer() {
        let html = render()
        #expect(html.contains("<a class=\"nav-link\" href=\"/login\">Log in</a>"))
        #expect(html.contains("session-idle-timeout-seconds") == false)
        #expect(html.contains("/idle-logout.js") == false)
    }

    @Test func theHeadingFallsBackToTheUsername() {
        #expect(render(displayName: nil).contains("<h1>ada — Courses</h1>"))
        #expect(render(displayName: "").contains("<h1>ada — Courses</h1>"))
    }

    @Test func noEnrollmentsAndNoCoursesShowTheirEmptyStates() {
        let html = render()
        #expect(html.contains("<p class=\"empty\">Not enrolled in any courses.</p>"))
        #expect(html.contains("<p class=\"empty\">No active courses are available.</p>"))
        #expect(html.contains("<table") == false)
    }

    @Test func enrolledInEverythingSaysSo() {
        #expect(render(enrolled: [fall]).contains("<p class=\"empty\">Enrolled in all active courses.</p>"))
    }

    @Test func anEnrolledRowShowsTheTermAndARemoveFormWithItsToken() {
        let html = render(enrolled: [fall, untermed])
        #expect(html.contains("<td><strong>CS135</strong> Fall 2025</td>"))
        #expect(html.contains("<td><strong>CS136</strong></td>"))
        #expect(html.contains("action=\"/admin/users/U1/unenroll/C1\""))
        #expect(html.contains("<input type=\"hidden\" name=\"_csrf\" value=\"salt-token\">"))
        #expect(html.contains("<svg class=\"icon\" aria-hidden=\"true\"><use href=\"#i-trash\" /></svg>"))
    }

    @Test func theEnrollPickerLabelsEachOfferingWithItsTerm() {
        let html = render(available: [fall, untermed])
        #expect(html.contains("<option value=\"C1\">CS135 Fall 2025 — Design</option>"))
        #expect(html.contains("<option value=\"C2\">CS136 — Algorithms</option>"))
    }

    @Test func userTextIsEscapedInTextAndAttributes() {
        let hostile = AdminCourseRef(id: "\"><x", code: "<b>", name: "a&b", termLabel: nil)
        let html = render(displayName: "<script>alert(1)</script>", enrolled: [hostile])
        #expect(html.contains("<script>alert(1)</script>") == false)
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("<strong>&lt;b&gt;</strong>"))
        #expect(html.contains("a&amp;b"))
        // Attribute values are always double-quoted, so escaping `&` and `"`
        // is enough to keep a value from closing its attribute.
        #expect(html.contains("unenroll/&quot;><x\""))
    }

    @Test func theFlashBannersCarryTheirRoles() {
        let html = FlashBanners(flash: FlashMessages(success: "Saved", notice: nil, error: "Oops")).render()
        #expect(
            html == "<div class=\"flash flash-success\" role=\"status\">Saved</div>"
                + "<div class=\"flash flash-error\" role=\"alert\">Oops</div>")
    }

    @Test func theEditorsNoticeRendersAsASuccessBanner() {
        let html = FlashBanners(flash: FlashMessages(success: nil, notice: "Saved draft", error: nil)).render()
        #expect(html == "<div class=\"flash flash-success\" role=\"status\">Saved draft</div>")
    }

    @Test func aPageStyleKeepsCSSCombinatorsIntact() {
        #expect(PageStyle(".a > .b { color: red; }").render() == "<style>.a > .b { color: red; }</style>")
    }
}
