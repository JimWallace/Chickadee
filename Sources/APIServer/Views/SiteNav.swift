// APIServer/Views/SiteNav.swift
//
// The site nav and the course tab strip.

import Elementary

struct SiteNav: HTML {
    let page: PageRequestContext

    var body: some HTML {
        nav(.class("nav")) {
            a(.class("nav-brand"), .href("/")) {
                // The flex gap, not these spaces, sets the visible spacing.
                img(.class("nav-brand-logo"), .src(page.asset("/images/chickadee-icon-alt.png")), .alt(""))
                " "
                span { "Chickadee" }
            }
            if let user = page.currentUser {
                staffEntry(for: user)
                if user.isAdmin {
                    a(.class("nav-link"), .href("/admin")) { "Admin" }
                }
                accountMenu(for: user)
            } else {
                a(.class("nav-link"), .href("/login")) { "Log in" }
            }
        }
    }

    /// One taught course: a direct link through `/activate`. More than one: a
    /// menu whose items each switch the active course and land on its
    /// instructor view.
    @HTMLBuilder private func staffEntry(for user: CurrentUserContext) -> some HTML {
        if let course = user.primaryStaffCourse {
            form(.method(.post), .action("/courses/\(course.id)/activate"), .class("inline-form")) {
                CSRFField(token: page.csrfToken)
                input(.type(.hidden), .name("next"), .value("/instructor"))
                button(.class("btn-link nav-link"), .type(.submit)) { "Instructor" }
            }
        } else if user.showStaffTabs {
            div(.class("nav-dropdown"), .dataFlag("nav-dropdown")) {
                button(
                    .type(.button), .class("nav-link nav-dropdown-toggle"),
                    .ariaHasPopup(true), .ariaExpanded(false)
                ) {
                    span { "Instructor" }
                    " "
                    span(.class("nav-dropdown-caret"), .ariaHidden) { "▾" }
                }
                div(.class("nav-dropdown-menu"), .role("menu")) {
                    for course in user.staffCourses {
                        form(.method(.post), .action("/courses/\(course.id)/activate"), .class("contents-form")) {
                            CSRFField(token: page.csrfToken)
                            input(.type(.hidden), .name("next"), .value("/instructor"))
                            button(.type(.submit), .role("menuitem"), .class("nav-dropdown-item")) {
                                "\(course.code)\(course.termLabel.map { " \($0)" } ?? "") — \(course.name)"
                            }
                            .attributes(.class("nav-dropdown-item-active"), when: course.isActive)
                        }
                    }
                }
            }
        }
    }

    private func accountMenu(for user: CurrentUserContext) -> some HTML {
        div(.class("nav-dropdown nav-user"), .dataFlag("nav-dropdown")) {
            button(
                .type(.button), .class("nav-link nav-username nav-dropdown-toggle"),
                .ariaHasPopup(true), .ariaExpanded(false), .ariaLabel("Account menu")
            ) {
                span { user.preferredName ?? user.displayName ?? user.username }
                " "
                span(.class("nav-dropdown-caret"), .ariaHidden) { "▾" }
            }
            div(.class("nav-dropdown-menu"), .role("menu")) {
                a(.class("nav-dropdown-item"), .href("/account"), .role("menuitem")) { "Account" }
                form(.method(.post), .action("/logout"), .class("contents-form")) {
                    CSRFField(token: page.csrfToken)
                    button(.class("nav-dropdown-item"), .type(.submit), .role("menuitem")) { "Log out" }
                }
            }
        }
    }
}

struct CourseTabs: HTML {
    let user: CurrentUserContext
    let csrfToken: String

    var body: some HTML {
        nav(.class("course-tabs"), .ariaLabel("Courses")) {
            for course in user.enrolledCourses {
                form(.method(.post), .action("/courses/\(course.id)/activate"), .class("contents-form")) {
                    CSRFField(token: csrfToken)
                    button(.type(.submit), .class("course-tab"), .ariaCurrent(course.isActive ? "page" : "false")) {
                        "\(course.code)\(course.termShortLabel.map { " \($0)" } ?? "")"
                    }
                    .attributes(.class("course-tab-active"), when: course.isActive)
                }
            }
        }
    }
}
