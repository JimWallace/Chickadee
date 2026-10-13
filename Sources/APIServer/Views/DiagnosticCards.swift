// APIServer/Views/DiagnosticCards.swift
//
// The diagnostic cards. `DiagnosticCards` draws the stat cards of the
// per-assignment submissions page (`AssignmentSubmissionsPage`), each with an
// optional server-rendered sparkline. `MetricsDiagnosticCard` is the empty
// shell on the admin and instructor dashboards that a page script fills from
// `/metrics/cards`.

import Elementary

/// The `.diagnostics-cards` row for an assignment's `AssignmentStatCard`s.
///
/// - `hasSpark`: a fixed distribution sparkline (grade spread, attempts) drawn
///   from pre-normalized bar heights.
/// - `cyclable`: the Submissions card, with three pre-rendered windows
///   (24h/7d/30d). The 24h view shows first, and
///   `Public/assignment-submissions.js` reveals the others on press.
///
/// The caller owns the enclosing `<section>`.
struct DiagnosticCards: HTML {
    let metrics: [AssignmentStatCard]

    var body: some HTML {
        div(.class("diagnostics-cards")) {
            for metric in metrics {
                if metric.cyclable {
                    CyclableDiagnosticCard(metric: metric)
                } else {
                    div(.class("diagnostic-card")) {
                        div(.class("diagnostic-label")) { metric.label }
                        div(.class("diagnostic-value")) { metric.value }
                        if metric.hasSpark {
                            div(.class("diagnostic-spark"), .ariaHidden) {
                                for bar in metric.bars {
                                    SparkSlot(bar: bar)
                                }
                            }
                            span(.class("visually-hidden")) { metric.sparkSummary }
                        }
                    }
                }
            }
        }
    }
}

/// The Submissions card: one sparkline per time window, all but the first
/// hidden.
private struct CyclableDiagnosticCard: HTML {
    let metric: AssignmentStatCard

    var body: some HTML {
        div(
            .class("diagnostic-card diagnostic-card-cyclable"), .dataFlag("subm-trend"), .role("button"),
            .tabindex(0),
            .ariaLabel(
                "Submissions over time. Press to change the time window between 24 hours, 7 days, and 30 days.")
        ) {
            div(.class("diagnostic-label")) {
                span(.class("diagnostic-window-chip"), .dataFlag("subm-chip")) { metric.windowChip }
                " \(metric.label)"
            }
            div(.class("diagnostic-value"), .dataFlag("subm-value")) { metric.value }
            for window in metric.windows {
                div(
                    .class("diagnostic-spark js-subm-trend-spark"), .data("subm-window", value: window.key),
                    .data("subm-headline", value: window.headline), .ariaHidden
                ) {
                    for bar in window.bars {
                        SparkSlot(bar: bar)
                    }
                }
                .attributes(.hidden, when: window.initiallyHidden)
            }
        }
    }
}

/// One bar. An empty bucket draws as a faint baseline tick.
private struct SparkSlot: HTML {
    let bar: SparklineBar

    var body: some HTML {
        div(.class("spark-slot"), .title(bar.title)) {
            // A custom-property assignment: the bar's height.
            span(.class("spark-fill"), .custom(name: "style", value: "--bar-h:\(bar.heightPercent)%")) {}
                .attributes(.class("spark-fill-empty"), when: bar.isEmpty)
        }
    }
}

/// A cyclable dashboard card that a page script fills from `/metrics/cards`:
/// the value, the sparkline and the time window, which starts at 24 hours.
struct MetricsDiagnosticCard: HTML {
    /// The data attribute the page script finds the card by.
    enum Hook: String {
        /// The admin dashboard (admin-dashboard.js).
        case admin = "card"
        /// The instructor dashboard (assignments.js).
        case instructor = "idash-card"
    }

    let hook: Hook
    let key: String
    let label: String
    /// The label in sentence case, for the screen-reader name.
    let spoken: String
    let valueID: String

    var body: some HTML {
        div(
            .class("diagnostic-card diagnostic-card-cyclable"), .data(hook.rawValue, value: key), .role("button"),
            .tabindex(0), .ariaLabel("\(spoken), last 24 hours. Press to change time window.")
        ) {
            div(.class("diagnostic-label")) {
                span(.class("diagnostic-window-chip")) { "24h" }
                " \(label)"
            }
            div(.class("diagnostic-value"), .id(valueID)) { "—" }
            div(.class("diagnostic-spark"), .ariaHidden) {}
        }
    }
}
