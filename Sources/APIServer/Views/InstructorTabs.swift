// APIServer/Views/InstructorTabs.swift
//
// The instructor-area chrome: the page's hidden
// h1 and the tab bar. Every instructor tabbed page opens with
// `InstructorTabs`, and no other view writes the `instructor-tab` classes
// (SwiftLint `elementary_tabs_only_in_component`).

import Elementary

/// One instructor page. The raw value is the tab's name in the markup.
enum InstructorTab: String, CaseIterable, Sendable {
    case overview, activity, students, groups
    case slipDays = "slip-days"
    case datasets
    case brightspace, mcp, github
    case newTerm = "new-term"

    /// The hidden h1 and the tab label.
    var label: String {
        switch self {
        case .overview: "Overview"
        case .activity: "Activity"
        case .students: "Students"
        case .groups: "Groups"
        case .slipDays: "Slip days"
        case .datasets: "Datasets"
        case .brightspace: "LEARN"
        case .mcp: "AI agents"
        case .github: "GitHub"
        case .newTerm: "New term"
        }
    }

    /// The tabs the bar shows, in order. GitHub has a page and a heading but
    /// no tab: the assignment editor links to it.
    static let shown: [InstructorTab] = [
        .overview, .activity, .students, .groups, .slipDays, .datasets, .brightspace, .mcp, .newTerm,
    ]

    fileprivate var href: String {
        self == .overview ? "/instructor" : "/instructor/\(rawValue)"
    }
}

struct InstructorTabs: HTML {
    let active: InstructorTab

    var body: some HTML {
        h1(.class("visually-hidden")) { "Instructor — \(active.label)" }
        nav(.class("instructor-tabs"), .ariaLabel("Instructor sections")) {
            for tab in InstructorTab.shown {
                a(.class("instructor-tab"), .href(tab.href)) { tab.label }
                    .attributes(.ariaCurrent("page"), when: tab == active)
            }
        }
    }
}
