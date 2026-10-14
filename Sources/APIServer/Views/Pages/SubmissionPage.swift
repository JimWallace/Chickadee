// APIServer/Views/Pages/SubmissionPage.swift
//
// GET /submissions/:id: one submission's results. The header with the
// download and the grade band, the class goals, then the outcome tables, one
// per test-suite section, with the masked secret rows under each. While the
// submission waits for a runner, the page shows a spinner and
// `submission-root[data-pending]` tells the page script to poll.

import Elementary

struct SubmissionPage: HTML {
    let page: PageRequestContext
    /// The view model the presenter builds (`buildSubmissionContext`).
    let result: SubmissionContext

    var body: some HTML {
        BaseLayout(title: "Submission \(result.submissionID)", page: page) {
            PageStyle(
                """
                .class-goals-block { margin: 1rem 0; }
                .class-goals-heading { font-size: var(--text-lg); margin: 0 0 0.5rem; }
                .class-goal { margin: 0.5rem 0; }
                .class-goal-row { display: flex; justify-content: space-between; align-items: baseline; gap: 0.5rem; }
                .class-goal-name { font-weight: 600; }
                .class-goal-reward { font-variant-numeric: tabular-nums; white-space: nowrap; }
                .class-goal-progress { width: 100%; height: 0.6rem; }
                .class-goal-status { font-size: var(--text-base); margin-top: 0.15rem; }
                .class-goal-detail { font-size: var(--text-base); margin: 0.15rem 0 0; }
                """
            )
            div(
                .id("submission-root"), .data("submission-id", value: result.submissionID),
                .data("pending", value: String(result.isPending))
            ) {
                header
                if !result.classGoals.isEmpty {
                    section(.class("class-goals-block")) {
                        h2(.class("class-goals-heading")) { "Class goals" }
                        for goal in result.classGoals {
                            SubmissionClassGoal(goal: goal)
                        }
                    }
                }
                if let tile = result.compositeTile {
                    CompositeTileSection(tile: tile)
                }
                if result.isPending {
                    div(.class("pending-box")) {
                        div(.class("spinner")) {}
                        p { "Waiting for a runner to pick up your submission…" }
                    }
                } else {
                    results
                }
            }
            if result.compositeTile != nil {
                script(.src(page.asset("/class-composite-core.js"))) {}
                script(.src(page.asset("/class-composite.js"))) {}
            }
        }
    }

    private var header: some HTML {
        div(.class("submission-header")) {
            div(.class("submission-header-row")) {
                h1 { "Submission" }
                div {
                    a(.class("btn action-btn"), .href("/api/v1/submissions/\(result.submissionID)/download")) {
                        if let filename = result.submissionFilename {
                            "Download \(filename)"
                        } else {
                            "Download submission"
                        }
                    }
                    if let url = result.openInNotebookURL {
                        " "
                        a(.class("btn action-btn"), .href(url)) { "Open in notebook" }
                    }
                    if let url = result.leaderboardURL {
                        " "
                        a(.class("btn action-btn"), .href(url)) { "Leaderboard" }
                    }
                    if let url = result.diffURL {
                        " "
                        a(.class("btn action-btn"), .href(url)) { "Diff against starter" }
                    }
                }
            }
            if let commit = result.sourceCommit {
                p(.class("card-meta")) {
                    "From GitHub: \(commit.repositoryName) at "
                    a(.href(commit.commitURL)) { code { commit.shortSHA } }
                }
            }
            if !result.isPending && !result.buildFailed {
                scoreRow
            }
        }
    }

    private var scoreLine: String {
        result.isWeighted
            ? "\(result.earnedPoints) / \(result.totalPoints) points"
            : "\(result.passCount) / \(result.totalTests) tests passed"
    }

    private var scoreRow: some HTML {
        div(.class("submission-score-row")) {
            div(.class("score-summary")) {
                p(.class("card-meta")) { "Grade" }
                if result.gradeIsOverridden {
                    p(.class("score score-header")) {
                        span(.class("score-figure grade-override-active")) { result.overrideGradeText ?? "" }
                        " "
                        span(
                            .class("grade-override-tag"),
                            .title("Your instructor set this grade for the assignment")
                        ) { "overridden" }
                    }
                    p(.class("score score-autograded")) { "Autograded: \(result.gradePercent)% · \(scoreLine)" }
                } else {
                    p(.class("score score-header")) {
                        span(.class("score-figure")) { "\(result.gradePercent)%" }
                    }
                    p(.class("score score-autograded")) { scoreLine }
                }
            }
            div(.class("diagnostics-cards")) {
                SubmissionDiagnosticCard(value: result.passCount, label: "Passed", alert: false)
                SubmissionDiagnosticCard(value: result.failCount, label: "Failed", alert: result.failCount > 0)
                SubmissionDiagnosticCard(value: result.errorCount, label: "Errors", alert: false)
                SubmissionDiagnosticCard(value: result.skippedCount, label: "Skipped", alert: false)
            }
            if let delta = result.deltaHeaderText {
                p(.class("score-delta")) { span(.class("delta-summary")) { delta } }
            }
            if !result.badges.isEmpty {
                div(.class("achievement-badges achievement-badges-full")) {
                    for (position, badge) in result.badges.enumerated() {
                        if position > 0 { " " }
                        span(.class("achievement-badge"), .title(badge.tooltip)) { badge.label }
                    }
                }
            }
        }
    }

    @HTMLBuilder private var results: some HTML {
        if result.hasWarnings {
            div(.class("warning-box")) {
                h2 { "Warnings" }
                ul(.class("warning-list")) {
                    for warning in result.warnings {
                        li { warning }
                    }
                }
            }
        }
        if !result.releasedFeedback.isEmpty {
            section(.class("page-section")) {
                h2 { "Feedback on your written answers" }
                p(.class("card-meta")) { "Drafted with AI assistance and reviewed by course staff." }
                for paragraph in result.releasedFeedback {
                    p { paragraph }
                }
            }
        }
        if let solutionURL = result.solutionURL {
            div(.class("notice-box")) {
                strong { "Solution available" }
                " — "
                a(.href(solutionURL)) { "view the reference solution" }
                " for this assignment."
            }
        }
        if result.buildFailed {
            div(.class("error-box")) {
                h2 { "Build failed" }
                if let compilerOutput = result.compilerOutput {
                    pre(.class("compiler-output")) { compilerOutput }
                }
            }
        } else {
            if result.secretRevealActive {
                div(.class("notice-box")) {
                    "🔓 "
                    strong { "Secret tests revealed" }
                    " — you used your reveal token for this assignment, so hidden-test details are shown on all of your submissions."
                }
            }
            for block in result.sectionedOutcomes {
                SubmissionSectionBlock(page: page, result: result, block: block)
            }
        }
    }
}

/// One count tile in the score band.
private struct SubmissionDiagnosticCard: HTML {
    let value: Int
    let label: String
    /// Draws the value in the alert colour (a failure count above zero).
    let alert: Bool

    var body: some HTML {
        div(.class("diagnostic-card")) {
            div(.class(alert ? "diagnostic-value diagnostic-value-alert" : "diagnostic-value")) { String(value) }
            div(.class("diagnostic-label")) { label }
        }
    }
}

/// One class goal and its progress bar.
private struct SubmissionClassGoal: HTML {
    let goal: ClassGoalView

    private var status: String {
        var text = goal.met ? "✅ Reached!" : "\(goal.progressPercent)% of the way"
        text += " · \(goal.studentsMeeting) / \(goal.denominator) \(goal.studentsLabel)"
        if let coverage = goal.coverageSummary { text += " · \(coverage)" }
        if goal.locked { text += " · final" }
        return text
    }

    var body: some HTML {
        div(.class("class-goal")) {
            div(.class("class-goal-row")) {
                span(.class("class-goal-name")) { goal.name }
                " "
                span(.class("class-goal-reward")) { goal.rewardLabel }
            }
            progress(.class("class-goal-progress"), .max(100), .value(goal.progressPercent)) {
                "\(goal.progressPercent)%"
            }
            div(.class("class-goal-status")) { status }
            if let detail = goal.detail {
                p(.class("class-goal-detail")) { detail }
            }
        }
    }
}

/// One test-suite section: its outcome table, then its masked secret rows.
private struct SubmissionSectionBlock: HTML {
    let page: PageRequestContext
    let result: SubmissionContext
    let block: SectionedOutcomes

    var body: some HTML {
        section(.class("submission-section-block")) {
            if let name = block.sectionName {
                h2(.class("submission-section-heading")) { name }
            }
            if !block.outcomes.isEmpty {
                div(.class("table-scroll")) {
                    table(.class("results-table")) {
                        thead {
                            tr {
                                th { "Test" }
                                th { "Tier" }
                                if result.hasDelta {
                                    th(.class("delta-col"), .title("Change vs previous attempt")) { "vs last" }
                                }
                                th { "Mark" }
                            }
                        }
                        tbody {
                            for outcome in block.outcomes {
                                SubmissionOutcomeRows(outcome: outcome, hasDelta: result.hasDelta)
                            }
                        }
                    }
                }
            }
            if let stake = block.secretStake {
                SubmissionSecretBlock(page: page, result: result, block: block, stake: stake)
            }
        }
    }
}

/// The masked secret rows of one section, with the reveal-token offer.
private struct SubmissionSecretBlock: HTML {
    let page: PageRequestContext
    let result: SubmissionContext
    let block: SectionedOutcomes
    let stake: String

    var body: some HTML {
        div(.class("tier-summary-row tier-summary-secret")) {
            span(.class("tier")) { "secret" }
            " "
            span(.class("tier-summary-counts")) { stake }
            " "
            span(.class("tier-summary-note")) { "names and output are visible only to your instructor" }
            if result.secretRevealAvailable {
                form(
                    .class("secret-reveal-action"), .method(.post),
                    .action("/testsetups/\(result.testSetupID)/reveal-secret"),
                    .data(
                        "confirm",
                        value:
                            "Use your one reveal token for this assignment? This permanently reveals the secret test results for all of your submissions on this assignment and cannot be undone."
                    )
                ) {
                    CSRFField(token: page.csrfToken)
                    " "
                    input(.type(.hidden), .name("submissionID"), .value(result.submissionID))
                    " "
                    button(.class("btn action-btn"), .type(.submit)) { "Reveal these tests" }
                }
            }
        }
        div(.class("table-scroll")) {
            table(.class("results-table")) {
                thead {
                    tr {
                        th { "Test" }
                        th { "Result" }
                        th { "Mark" }
                    }
                }
                tbody {
                    for row in block.secretRows {
                        tr(.class("status-\(row.status)")) {
                            td { div(.class("test-cell-main")) { code { row.testName } } }
                            td { row.shortResult }
                            td { SubmissionMark(outcome: row) }
                        }
                    }
                }
            }
        }
    }
}

/// The mark chip and, on a weighted assignment, the points beside it.
private struct SubmissionMark: HTML {
    let outcome: OutcomeRow

    var body: some HTML {
        span(.class("result-mark result-mark-\(outcome.markClass)")) { outcome.markLabel }
        if let points = outcome.pointsLabel {
            " "
            span(.class("points-label")) { points }
        }
    }
}

/// One outcome row, and the output row under it when the test did not pass.
private struct SubmissionOutcomeRows: HTML {
    let outcome: OutcomeRow
    let hasDelta: Bool

    var body: some HTML {
        tr(.class(outcome.isSkipped ? "status-skipped" : "status-\(outcome.status)")) {
            td {
                div(.class("test-cell-main")) {
                    code { outcome.testName }
                    if outcome.isSkipped {
                        div(.class("skip-reason")) { outcome.shortResult }
                    } else {
                        div(.class("test-short-result")) { outcome.shortResult }
                    }
                    if outcome.status == "pass", let longResult = outcome.longResult {
                        details(.class("test-output-details")) {
                            summary { "Show output ▸" }
                            pre(.class("test-output-pre")) { longResult }
                        }
                    }
                    if let hint = outcome.hint {
                        div(.class("test-hint")) {
                            "💡 "
                            strong { "Hint:" }
                            " \(hint)"
                        }
                    }
                }
                if let blocker = outcome.blockerName {
                    div(.class("skip-blocker")) {
                        "↳ blocked by "
                        code { blocker }
                    }
                }
            }
            td { span(.class("tier")) { outcome.tier } }
            if hasDelta {
                td(.class("delta-cell")) {
                    if outcome.deltaImproved {
                        span(.class("delta-improved"), .title("Was failing, now passing")) { "↑" }
                    }
                    if outcome.deltaRegressed {
                        if outcome.deltaImproved { " " }
                        span(.class("delta-regressed"), .title("Was passing, now failing")) { "↓" }
                    }
                }
            }
            td { SubmissionMark(outcome: outcome) }
        }
        // No output panel on a skipped row: it never ran, and the panel would
        // only repeat the skip reason already shown above.
        if !outcome.isSkipped, outcome.status != "pass", let longResult = outcome.longResult {
            tr(.class("test-output-row")) {
                td(.custom(name: "colspan", value: hasDelta ? "4" : "3")) {
                    details(.class("test-output-details")) {
                        summary { "Output" }
                        pre(.class("test-output-pre test-output-pre-wide")) { longResult }
                    }
                    .attributes(.custom(name: "open"), when: outcome.isFirstFailureOutput)
                }
            }
        }
    }
}
