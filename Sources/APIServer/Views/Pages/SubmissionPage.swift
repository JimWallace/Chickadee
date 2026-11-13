// APIServer/Views/Pages/SubmissionPage.swift
//
// GET /submissions/:id: one submission's results. The header with the
// download and the grade band, the class goals, then the outcome tables, one
// per test-suite section, with the masked secret rows under each. While the
// submission has no result, the page shows its state ("Queued", "Grading") in
// a region `table-poll.js` refreshes (`?fragment=state`); `app.js` reloads the
// page once the region reports a final state.

import Core
import Elementary

struct SubmissionPage: HTML {
    let page: PageRequestContext
    /// The view model the presenter builds (`buildSubmissionContext`).
    let result: SubmissionContext
    /// The answer to a "Fill a hole" request (`SpareFlash`).
    var flash = FlashMessages()

    var body: some HTML {
        BaseLayout(title: tabTitle, page: page, flash: flash) {
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
                    CompositeTileSection(tile: tile, csrfToken: page.csrfToken, submissionID: result.submissionID)
                }
                if result.isPending {
                    div(
                        .class("pending-box js-submission-state"), .role("status"),
                        .data("poll-url", value: "/submissions/\(result.submissionID)?fragment=state"),
                        .data("poll-swap", value: "region"), .data("poll-interval", value: "2000")
                    ) {
                        SubmissionStateRegion(status: SubmissionStatus(rawValue: result.status))
                    }
                } else {
                    results
                }
            }
            if let earned = result.bird?.earned {
                EarnedToast(page: page, earned: earned)
            }
            if result.bird?.celebration != nil {
                script(.src(page.asset("/celebrate-core.js"))) {}
                script(.src(page.asset("/celebrate.js"))) {}
            }
            // After celebrate.js, so the toast can wait for its pop.
            if result.bird?.earned != nil {
                script(.src(page.asset("/earned-toast.js"))) {}
            }
            if result.compositeTile != nil {
                script(.src(page.asset("/class-composite-core.js"))) {}
                script(.src(page.asset("/class-composite.js"))) {}
            }
            if result.isPending {
                script(.src(page.asset("/table-poll.js"))) {}
            }
        }
    }

    /// The assignment and the attempt; never a database ID.
    private var tabTitle: String {
        guard let title = result.assignmentTitle else { return "Submission results" }
        return "\(title) — Attempt \(result.attemptNumber)"
    }

    private var header: some HTML {
        div(.class("submission-header")) {
            div(.class("submission-header-row")) {
                div {
                    h1 { result.assignmentTitle ?? "Submission" }
                    p(.class("titlebar-subtitle")) {
                        "Attempt \(result.attemptNumber)"
                        if let iso = result.submittedAtISO, let text = result.submittedAtText {
                            " · submitted "
                            span(.class("js-relative-time"), .data("iso", value: iso)) { text }
                        }
                    }
                }
                div {
                    if let url = result.backURL, let label = result.backLabel {
                        a(.class("btn action-btn"), .href(url)) { label }
                        " "
                    }
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

    private var scoreSummary: some HTML {
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
                        .attributes(.class("score-figure-perfect"), when: showsPerfectGrade)
                }
                p(.class("score score-autograded")) { scoreLine }
            }
        }
    }

    /// The student's own full-marks result shows its grade in the open
    /// colour on every load, so the end of the celebration is the page as
    /// it always reads (docs/result-celebration.md).
    private var showsPerfectGrade: Bool { result.bird?.isFullMarks ?? false }

    private var scoreRow: some HTML {
        div(.class("submission-score-row")) {
            // The bird joins the grade's group, so the band stays two groups.
            if let bird = result.bird {
                if let celebration = bird.celebration {
                    div(
                        .class("submission-bird"), .data("celebrate", value: celebration.state.rawValue),
                        .data("grade-from", value: String(celebration.gradeFrom)),
                        .data("grade-to", value: String(celebration.gradeTo)),
                        .data("announce", value: celebration.announcement)
                    ) {
                        Avatar(avatar: bird.avatar)
                        scoreSummary
                        if let gain = celebration.gain {
                            span(.class("tier tier-open js-grade-gain")) { "+\(gain)%" }
                        }
                    }
                    .attributes(.class("submission-bird-cheer"), when: bird.reaction == .cheer)
                    p(.class("visually-hidden js-celebrate-live"), .custom(name: "aria-live", value: "polite")) {}
                } else {
                    div(.class("submission-bird")) {
                        Avatar(avatar: bird.avatar)
                        scoreSummary
                    }
                    .attributes(.class("submission-bird-cheer"), when: bird.reaction == .cheer)
                    .attributes(.class("submission-bird-other"), when: !bird.isOwn)
                }
            } else {
                scoreSummary
            }
            div(.class("diagnostics-cards")) {
                SubmissionDiagnosticCard(value: result.passCount, label: "Passed", alert: false)
                SubmissionDiagnosticCard(value: result.failCount, label: "Failed", alert: result.failCount > 0)
                SubmissionDiagnosticCard(value: result.errorCount, label: "Errors", alert: false)
                SubmissionDiagnosticCard(value: result.timeoutCount, label: "Timed out", alert: false)
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
        var text = goal.met ? "Reached" : "\(goal.progressPercent)% of the way"
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
                            summary { "Show output" }
                            pre(.class("test-output-pre")) { longResult }
                        }
                    }
                    if let hint = outcome.hint {
                        div(.class("test-hint")) {
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
                        summary { "Show output" }
                        pre(.class("test-output-pre test-output-pre-wide")) { longResult }
                    }
                    .attributes(.custom(name: "open"), when: outcome.isFirstFailureOutput)
                }
            }
        }
    }
}

/// The pending band's contents: the state's one label and, while it lasts, a
/// spinner. Rendered inline and as the `?fragment=state` poll response, so
/// the refresh cannot drift from the page. A final state carries
/// `data-submission-final`, which `app.js` answers by reloading the page.
struct SubmissionStateRegion: HTML {
    let status: SubmissionStatus?

    var body: some HTML {
        if let status, status.awaitsResult {
            div(.class("spinner")) {}
            p { status.displayLabel }
        } else {
            p(.data("submission-final", value: "true")) { "Loading results" }
        }
    }
}
