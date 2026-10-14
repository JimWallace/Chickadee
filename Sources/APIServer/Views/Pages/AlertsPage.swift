// APIServer/Views/Pages/AlertsPage.swift
//
// GET /admin/alerts: the health-alert webhook, the rules and the recent
// firings. The admin tabbed exemplar (docs/ui-design.md).

import Elementary

struct AlertsPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let enabled: Bool
    let webhookURL: String
    let webhookURLFromEnvironment: Bool
    let rules: [AdminAlertsRuleRow]
    /// The webhook shortened from the middle for display; "Not set" when empty.
    let webhookDisplay: String
    /// The newest paged firing's time and result, or nil before any.
    let lastDelivery: (iso: String, result: String)?
    /// Recent firings under their day headings, newest first.
    let firingDays: [DayGroup<AdminAlertFiringRow>]

    var body: some HTML {
        BaseLayout(title: "Server Health Alerts", page: page, flash: flash) {
            AdminTabs(active: .alerts, page: page)
            webhookSection
            rulesSection
            firingsSection
        }
    }

    // MARK: - Webhook

    private var webhookSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    "Health alerts "
                    if enabled {
                        span(.class("tier tier-open")) { "Enabled" }
                    } else {
                        span(.class("tier tier-closed")) { "Disabled" }
                    }
                }
                form(.method(.post), .action("/admin/alerts/test"), .class("form-flush")) {
                    CSRFField(token: page.csrfToken)
                    button(.class("btn action-btn"), .type(.submit)) { "Send test alert" }
                }
            }
            if !enabled {
                FlashBanner(.warning) {
                    strong { "Alerting is off." }
                    " Set "
                    code { "ALERT_ENABLED=1" }
                    " and restart to evaluate rules."
                }
            }
            div(.class("card section-gap")) {
                div(.class("facts-actions")) {
                    webhookEditor
                }
                dl(.class("detail-grid")) {
                    dt { "Webhook" }
                    dd {
                        code { webhookDisplay }
                        if webhookURLFromEnvironment {
                            " "
                            span(.class("card-meta")) {
                                "A fallback is set in "
                                code { "ALERT_WEBHOOK_URL" }
                            }
                        }
                    }
                    dt { "Last delivery" }
                    dd {
                        if let lastDelivery {
                            "\(lastDelivery.result) "
                            span(.class("card-meta js-relative-time"), .data("iso", value: lastDelivery.iso)) {
                                lastDelivery.iso
                            }
                        } else {
                            "No deliveries yet"
                        }
                    }
                }
            }
        }
    }

    private var webhookEditor: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "Edit webhook "
                Icon("i-chevron-down")
            }
            div(
                .class("add-section-popup card suite-section-popup"), .role("dialog"), .ariaLabel("Edit webhook")
            ) {
                form(.method(.post), .action("/admin/alerts/config"), .class("form popup-form")) {
                    CSRFField(token: page.csrfToken)
                    label(.class("form-label"), .for("alert-webhook")) {
                        "Webhook URL"
                        input(
                            .id("alert-webhook"), .class("form-input"), .type(.url), .name("webhookURL"),
                            .value(webhookURL), .placeholder("https://hooks.slack.com/services/…"))
                        span(.class("field-note field-note--muted")) { "Alerts POST here as they fire and resolve." }
                    }
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Save webhook" }
                    }
                }
            }
        }
    }

    // MARK: - Rules

    private var rulesSection: some HTML {
        section(.class("page-section")) {
            h2 { "Rules" }
            table(.class("results-table section-items section-items--manage")) {
                AlertsColGroup()
                thead(.class("visually-hidden")) {
                    tr {
                        th(.custom(name: "scope", value: "col")) { "Rule" }
                        th(.custom(name: "scope", value: "col")) { "Condition" }
                        th(.custom(name: "scope", value: "col")) { "Status" }
                        th(.custom(name: "scope", value: "col")) { "Last fired" }
                    }
                }
                tbody {
                    for rule in rules {
                        AlertRuleRow(rule: rule)
                    }
                }
            }
        }
    }

    // MARK: - Recent firings

    // The audit log's shape: when, what, how it went. The actor is left out,
    // because a rule fires itself and a column reading "system" on every row
    // carries no information. The summary is the reading a firing exists to
    // deliver ("queue backed up: 64 pending"); how it was delivered is one line
    // under it, in red when the page did not reach the operator. When stays
    // relative: a firing is operational activity where recency is the
    // question, and the audit log is the forensic table that carries the
    // absolute instant.
    private var firingsSection: some HTML {
        section(.class("page-section")) {
            h2 { "Recent firings" }
            if firingDays.allSatisfy(\.rows.isEmpty) {
                p(.class("empty")) { "No alerts have fired since startup." }
            } else {
                table(.class("results-table section-items section-items--manage")) {
                    AlertsColGroup()
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Event" }
                            th(.custom(name: "scope", value: "col")) { "Summary" }
                            th(.custom(name: "scope", value: "col")) { "Outcome" }
                            th(.custom(name: "scope", value: "col")) { "When" }
                        }
                    }
                    tbody {
                        for day in firingDays {
                            AlertFiringDay(day: day)
                        }
                    }
                }
            }
        }
    }
}

/// The column widths both alert tables share.
private struct AlertsColGroup: HTML {
    var body: some HTML {
        colgroup {
            col(.class("section-items-tile"))
            col()
            col(.class("section-items-count"))
            col(.class("section-items-seen col-hide-phone"))
        }
    }
}

/// One rule: its condition, whether it is firing, and when it last fired.
private struct AlertRuleRow: HTML {
    let rule: AdminAlertsRuleRow

    private var lastFiredAt: String? {
        guard let fired = rule.lastFiredAt, !fired.isEmpty else { return nil }
        return fired
    }

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: rule.isFiring ? "alert" : "ok")) { Icon("i-bell") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { rule.humanReadable }
                div(.class("item-details")) {
                    "\(rule.thresholdText) · "
                    code { rule.rule }
                }
            }
            td {
                if rule.isFiring {
                    span(.class("tier tier-danger")) { "Firing" }
                } else {
                    span(.class("tier tier-open")) { "OK" }
                }
            }
            td(.class("col-hide-phone")) {
                if let lastFiredAt {
                    span(.class("js-relative-time"), .data("iso", value: lastFiredAt)) { lastFiredAt }
                } else {
                    "Never"
                }
                div(.class("item-details")) { "last fired" }
            }
        }
    }
}

/// One day's heading and its firings.
private struct AlertFiringDay: HTML {
    let day: DayGroup<AdminAlertFiringRow>

    var body: some HTML {
        tr(.class("section-items-heading")) {
            td(.custom(name: "colspan", value: "4")) { strong { day.label } }
        }
        for firing in day.rows {
            AlertFiringRow(firing: firing)
        }
    }
}

/// One firing: what it said, how it was delivered, and when.
private struct AlertFiringRow: HTML {
    let firing: AdminAlertFiringRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: firing.resolved ? "ok" : "alert")) { Icon("i-bell") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { firing.summary }
                div(.class(firing.deliveryFailed ? "item-details item-details--danger" : "item-details")) {
                    code { firing.rule }
                    " · \(firing.deliveryText)"
                }
            }
            td {
                if firing.resolved {
                    span(.class("tier tier-open")) { "Resolved" }
                } else {
                    span(.class("tier tier-danger")) { "Fired" }
                }
            }
            td(.class("col-hide-phone js-relative-time"), .data("iso", value: firing.firedAt)) { firing.firedAt }
        }
    }
}
