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
            .tabindex(0)
        ) {
            div(.class("diagnostic-label")) {
                span(.class("diagnostic-window-chip"), .ariaHidden) { metric.windowChip }
                DiagnosticWindowSpoken(chip: metric.windowChip)
                " \(metric.label)"
            }
            div(.class("diagnostic-value"), .dataFlag("subm-value")) { metric.value }
            DiagnosticCardPressHint()
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
    let valueID: String

    var body: some HTML {
        div(
            .class("diagnostic-card diagnostic-card-cyclable"), .data(hook.rawValue, value: key), .role("button"),
            .tabindex(0)
        ) {
            div(.class("diagnostic-label")) {
                span(.class("diagnostic-window-chip"), .ariaHidden) { "24h" }
                DiagnosticWindowSpoken(chip: "24h")
                " \(label)"
            }
            div(.class("diagnostic-value"), .id(valueID)) { "—" }
            DiagnosticCardPressHint()
            div(.class("diagnostic-spark"), .ariaHidden) {}
        }
    }
}

/// What pressing a cyclable card does, for a screen reader only. A cyclable
/// card is a `button` named by its content: the window chip, the label, the
/// value and this hint. It has no `aria-label`, because a label that does not
/// contain the visible text fails WCAG 2.5.3 (axe
/// `label-content-name-mismatch`), and the page scripts would have to keep it
/// in step with the chip and the value.
struct DiagnosticCardPressHint: HTML {
    var body: some HTML {
        span(.class("visually-hidden")) { " Press to change the time window." }
    }
}

/// The time window of a cyclable card in words, for a screen reader only. The
/// chip beside it ("24h", "7d", "30d") is hidden from assistive technology,
/// because a screen reader reads it letter by letter or as a unit. The span
/// also carries every window's phrase as `data-phrase-<chip>`, so
/// `ChickadeeSparkline.setWindow` (Public/sparkline.js) can change it when the
/// window cycles without a second copy of the words.
struct DiagnosticWindowSpoken: HTML {
    let chip: String

    /// The chips a cyclable card shows, in `MetricsCardWindow.displayLabel`
    /// order, and what each one means.
    static let phrases: [(chip: String, phrase: String)] = [
        ("24h", "last 24 hours"), ("7d", "last 7 days"), ("30d", "last 30 days"),
    ]

    var body: some HTML {
        span(.class("visually-hidden js-window-spoken")) { Self.phrase(for: chip) }
            .attributes(contentsOf: Self.phrases.map { .data("phrase-\($0.chip)", value: $0.phrase) })
    }

    static func phrase(for chip: String) -> String {
        phrases.first { $0.chip == chip }?.phrase ?? chip
    }
}
