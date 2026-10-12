// Tests/APITests/ElementaryPageFixtures+StudentPages.swift
//
// The student dashboard, the account page, the submission results page, the
// GitHub submit page and the AI-assisted feedback review (the "StudentPages"
// group of the Leaf-to-Elementary migration), rendered for
// ElementaryPageGuardTests.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var studentPagesPages: [ElementaryPageFixture] {
        [indexPage, accountPage, submissionPage, gitHubSubmitPage, assignmentFeedbackPage]
    }

    // MARK: - Shared values

    /// What a dashboard row offers, for `dashboardRow`.
    struct DashboardRowOptions {
        var title: String? = "Lab <1> & co"
        var status = "open"
        var staffOnly = false
        var dueAt: String? = "Oct 1, 10:00"
        var opensAt: String?
        var hasExtension = false
        var submissions = 0
        var bestPercent: Int?
        var overridePercent: Int?
        var badgeCount = 0
        var extraBadges = 0
        var edit = false
        var upload = false
        var reset = false
        var slipDay = false
        var solution = false
        var leaderboard: String?
    }

    static func dashboardRow(_ id: String, _ options: DashboardRowOptions = DashboardRowOptions()) -> TestSetupRow {
        let anyAction = options.edit || options.upload || options.reset || options.slipDay
        return TestSetupRow(
            id: id, title: options.title, notebookURL: "/testsetups/\(id)/notebook",
            submitURL: "/testsetups/\(id)/submit", historyURL: "/testsetups/\(id)/history", suiteCount: 3,
            createdAt: "Sep 1", dueAt: options.dueAt, dueAtISO: options.dueAt.map { _ in "2026-10-01T14:00:00Z" },
            opensAtText: options.opensAt, status: options.status, staffOnly: options.staffOnly,
            isOpen: options.status == "open", canEdit: options.edit, gradingMode: "browser",
            submissionMode: "notebook", hasNotebook: true,
            latest: LatestSubmissionCell(
                count: options.submissions, latestSubmissionID: options.submissions > 0 ? "sub-\(id)" : nil,
                latestSubmittedAtText: options.submissions > 0 ? "Sep 30, 09:00" : nil,
                bestPercent: options.bestPercent, overridePercent: options.overridePercent),
            badges: (0..<options.badgeCount).map {
                AchievementBadge(id: "b\($0)", label: "🏅 Badge <\($0)>", tooltip: "Earned \"\($0)\"")
            },
            extraBadgeCount: options.extraBadges,
            extraBadgesTooltip: options.extraBadges > 0 ? "Streak, Speedy" : nil,
            hasActiveExtension: options.hasExtension,
            effectiveDueAtText: options.hasExtension ? "Oct 3, 10:00" : options.dueAt,
            effectiveDueAtISO: options.hasExtension ? "2026-10-03T14:00:00Z" : nil,
            showEditAction: options.edit, showUploadAction: options.upload,
            showResetNotebookAction: options.reset, hasAnyAction: anyAction, slipDayAvailable: options.slipDay,
            slipDayURL: "/testsetups/\(id)/slip-day",
            slipDayActionLabel: options.slipDay ? "Use a slip day — extends your deadline to Oct 2" : "",
            solutionAvailable: options.solution, solutionURL: "/testsetups/\(id)/notebook?view=solution",
            leaderboardURL: options.leaderboard)
    }

    /// One row per branch of the dashboard's row markup.
    static var dashboardRows: [TestSetupRow] {
        [
            dashboardRow("a1", DashboardRowOptions(edit: true, upload: true, reset: true)),
            dashboardRow(
                "a2",
                DashboardRowOptions(
                    status: "closed", submissions: 1, bestPercent: 80, badgeCount: 2, extraBadges: 3, edit: true,
                    slipDay: true, solution: true, leaderboard: "/testsetups/a2/leaderboard")),
            dashboardRow(
                "a3",
                DashboardRowOptions(
                    status: "extended", hasExtension: true, submissions: 4, bestPercent: 60, overridePercent: 95,
                    badgeCount: 1, upload: true)),
            dashboardRow("a4", DashboardRowOptions(staffOnly: true, dueAt: nil, opensAt: "Oct 9, 08:00")),
            dashboardRow("a5", DashboardRowOptions(title: nil, status: "unpublished", dueAt: nil)),
            dashboardRow("a6", DashboardRowOptions(status: "weird", dueAt: nil, submissions: 2, solution: true)),
        ]
    }

    /// A named section long enough to earn a Filter box, a short one, and
    /// the ungrouped bucket.
    static var dashboardGroups: [IndexDisplayGroup] {
        let materials = overviewItems.compactMap(\.content).map(IndexSectionItem.material)
        let rows = dashboardRows.map(IndexSectionItem.assignment)
        return [
            IndexDisplayGroup(name: "Labs & <Quizzes>", items: rows + Array(materials.prefix(2))),
            IndexDisplayGroup(name: "", items: Array(materials.dropFirst(2))),
            IndexDisplayGroup(name: nil, items: Array(rows.prefix(2))),
        ]
    }

    static var studentCourse: CourseContext {
        CourseContext(
            id: "c1", code: "CS135", name: "Design <& Recipes>", isActive: true, role: .student,
            termLabel: "Fall 2026", termShortLabel: "F26", urlKey: "CS135-F26")
    }

    static func avatar(_ seed: UInt64, size: AvatarSize = .standard) -> AvatarPresentation {
        AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: seed), size: size, accessibility: .decorative, isStaff: false)
    }

    static func handleChoice(locked: Bool, taken: Bool = false, wasLocked: Bool = false) -> AccountHandleChoice {
        let options =
            locked
            ? []
            : ["Hazy Cedar", "Quiet <Fern>", "Bold Ash"].enumerated().map { index, handle in
                AccountHandleOption(handle: handle, isCurrent: index == 0, avatar: avatar(7, size: .small))
            }
        return AccountHandleChoice(
            isLocked: locked, options: options, canChoose: !locked, wasTaken: taken, wasLocked: wasLocked)
    }

    static var accountEnrolledCourses: [AccountCourseRow] {
        [
            AccountCourseRow(
                id: "c1", code: "CS135", name: "Design", termLabel: "Fall 2026", enrollmentMode: "open",
                slipDaysText: "1 of 2 slip days left", handle: "Hazy Cedar",
                handleChoice: handleChoice(locked: false, taken: true)),
            AccountCourseRow(
                id: "c2", code: "CS136", name: "Algorithms <II>", termLabel: nil, enrollmentMode: "auto",
                slipDaysText: nil, handle: "Bold Ash", handleChoice: handleChoice(locked: true, wasLocked: true)),
            AccountCourseRow(
                id: "c3", code: "STAT230", name: "Probability", termLabel: "", enrollmentMode: "closed",
                slipDaysText: "", handle: nil, handleChoice: nil),
        ]
    }

    static var accountAvailableCourses: [AccountCourseRow] {
        [
            AccountCourseRow(
                id: "c4", code: "CS246", name: "Objects", termLabel: "Winter 2027", enrollmentMode: "open",
                slipDaysText: nil, handle: nil, handleChoice: nil)
        ]
    }

    /// One outcome row, for `submissionResult`.
    static func outcome(
        _ name: String, status: String, skipped: Bool = false, long: String? = nil, hint: String? = nil,
        improved: Bool = false, regressed: Bool = false, points: String? = nil, first: Bool = false
    ) -> OutcomeRow {
        var row = OutcomeRow(
            testName: name, tier: "public", status: status, shortResult: "\(status) <short> & more",
            longResult: long, markLabel: skipped ? "—" : status.capitalized, markClass: skipped ? "skipped" : status,
            isSkipped: skipped, blockerName: skipped ? "test_build" : nil, deltaImproved: improved,
            deltaRegressed: regressed, pointsLabel: points, hint: hint)
        row.isFirstFailureOutput = first
        return row
    }

    struct SubmissionOptions {
        var pending = false
        var buildFailed = false
        var overridden = false
        var weighted = false
        var hasDelta = true
        var extras = true
        var revealAvailable = true
        var revealActive = false
    }

    static func submissionResult(_ options: SubmissionOptions = SubmissionOptions()) -> SubmissionContext {
        let outcomes = [
            outcome("test_pass", status: "pass", long: "printed <ok>", improved: true, points: "2 pts"),
            outcome(
                "test_fail", status: "fail", long: "Traceback & <stack>", hint: "Check the base case.",
                regressed: true, first: true),
            outcome("test_error", status: "error", long: "boom", improved: true, regressed: true),
            outcome("test_skip", status: "fail", skipped: true, long: "never ran"),
            outcome("test_timeout", status: "timeout", long: "", points: "1 pts"),
        ]
        let secret = [
            outcome("hidden test 1", status: "pass", points: "3 pts"), outcome("hidden test 2", status: "fail"),
        ]
        let goals = [
            ClassGoalView(
                name: "Class <ace>", detail: "Everyone passes", rewardLabel: "+5 pts", progressPercent: 40,
                studentsMeeting: 12, denominator: 30, studentsLabel: "students", coverageSummary: "9 / 15 items found",
                met: false, locked: true),
            ClassGoalView(
                name: "Done", detail: nil, rewardLabel: "Badge", progressPercent: 100, studentsMeeting: 30,
                denominator: 30, studentsLabel: "students contributing", coverageSummary: nil, met: true,
                locked: false),
        ]
        let extras = options.extras
        return SubmissionContext(
            submissionID: "sub-1", testSetupID: "ts-1", status: options.pending ? "pending" : "complete",
            attemptNumber: 3, submissionFilename: extras ? "lab <1>.ipynb" : nil,
            openInNotebookURL: extras ? "/testsetups/ts-1/notebook?submissionID=sub-1" : nil,
            isPending: options.pending, isBrowserComplete: false, resultSource: "worker",
            buildFailed: options.buildFailed, compilerOutput: options.buildFailed ? "error: <missing> ;" : nil,
            hasWarnings: extras, warnings: extras ? ["Unused <import>", "Slow"] : [], outcomes: outcomes,
            sectionedOutcomes: [
                SectionedOutcomes(
                    sectionName: "Part & <A>", outcomes: outcomes, secretSummary: nil, secretRows: secret,
                    secretStake: "2 hidden tests · 3 of 4 points"),
                SectionedOutcomes(sectionName: nil, outcomes: [], secretSummary: nil, secretRows: [], secretStake: nil),
            ],
            passCount: 1, failCount: options.overridden ? 0 : 2, errorCount: 1, timeoutCount: 1, skippedCount: 1,
            totalTests: 5, gradePercent: 40, gradeIsOverridden: options.overridden,
            overrideGradeText: options.overridden ? "85%" : nil, executionTimeMs: 1200,
            isWeighted: options.weighted, totalPoints: 7, earnedPoints: "2.75", hasDelta: options.hasDelta,
            deltaHeaderText: options.hasDelta ? "↑ fixed 2 tests · ↓ broke 1 test since attempt 2" : nil,
            badges: extras
                ? [
                    AchievementBadge(id: "b", label: "🏅 First", tooltip: "First try"),
                    AchievementBadge(id: "c", label: "Two", tooltip: "t"),
                ] : [],
            classGoals: extras ? goals : [], hasClassGoals: extras,
            secretRevealAvailable: options.revealAvailable, secretRevealActive: options.revealActive,
            solutionURL: extras ? "/testsetups/ts-1/notebook?view=solution" : nil,
            leaderboardURL: extras ? "/testsetups/ts-1/leaderboard" : nil,
            diffURL: extras ? "/instructor/abc123/submissions/sub-1/diff" : nil,
            sourceCommit: nil,
            releasedFeedback: extras ? ["Good <reasoning>.", "Consider & revise."] : [])
    }

    /// One GitHub submit state per branch.
    static var gitHubStates: [GitHubSubmitState] {
        var needsLink = GitHubSubmitState(errorText: "Something <failed>.")
        needsLink.needsLink = true
        var install = GitHubSubmitState()
        install.installURL = "https://github.com/apps/x/installations/new?state=1&y=2"
        var courseMake = GitHubSubmitState()
        courseMake.courseRepositoryMode = true
        courseMake.canMakeCourseRepository = true
        var courseLoaded = GitHubSubmitState()
        courseLoaded.courseRepositoryMode = true
        courseLoaded.courseRepository = GitHubCourseRepositoryView(
            name: "org/lab1-ada", url: "https://github.com/org/lab1-ada", invited: false)
        courseLoaded.loaded = true
        var emptyOwn = GitHubSubmitState()
        emptyOwn.loaded = true
        emptyOwn.configureURL = "https://github.com/settings/installations/1"
        var full = emptyOwn
        full.repositories = [
            SelectOption(value: "1", label: "ada/one", selected: false),
            SelectOption(value: "2", label: "ada/<two>", selected: true),
        ]
        full.branches = [
            SelectOption(value: "main", label: "main", selected: true),
            SelectOption(value: "dev", label: "dev", selected: false),
        ]
        full.commit = GitHubSubmitCommitView(
            repositoryID: "2", repositoryName: "ada/<two>", branch: "main", sha: "abcdef1234567890",
            shortSHA: "abcdef1", summary: "Fix <bug> & tidy", commitURL: "https://github.com/ada/two/commit/abcdef1")
        var courseFull = full
        courseFull.courseRepositoryMode = true
        courseFull.courseRepository = GitHubCourseRepositoryView(
            name: "org/lab1-ada", url: "https://github.com/org/lab1-ada", invited: true)
        var noBranches = emptyOwn
        noBranches.repositories = full.repositories
        return [
            GitHubSubmitState(), needsLink, install, courseMake, courseLoaded, emptyOwn, full, courseFull, noBranches,
        ]
    }

    static var feedbackRows: [FeedbackReviewRow] {
        [
            FeedbackReviewRow(
                handle: "Hazy Cedar", student: "Ada <L>", username: "ada", state: "draft", stateLabel: "Draft",
                hasText: true, needsReview: true, draftText: "Good <work> & more.", draftedBy: "Claude",
                answers: [
                    FeedbackReviewText(index: 1, paragraphs: ["First <para>.", "Second."]),
                    FeedbackReviewText(index: 2, paragraphs: []),
                ]),
            FeedbackReviewRow(
                handle: "Bold Ash", student: "Bo", username: "bo", state: "released", stateLabel: "Released",
                hasText: true, needsReview: false, draftText: "", draftedBy: nil,
                answers: [FeedbackReviewText(index: 1, paragraphs: ["Answer."])]),
            FeedbackReviewRow(
                handle: "Quiet Fern", student: "Cy", username: "cy", state: "stale",
                stateLabel: "Resubmitted since", hasText: false, needsReview: true, draftText: "", draftedBy: nil,
                answers: []),
            FeedbackReviewRow(
                handle: "Dim Oak", student: "Di", username: "di", state: "none", stateLabel: "No draft",
                hasText: false, needsReview: false, draftText: "", draftedBy: nil, answers: []),
        ]
    }

    // MARK: - Pages

    static var indexPage: ElementaryPageFixture {
        func render(_ course: CourseContext?, _ groups: [IndexDisplayGroup], slip: String?) -> String {
            IndexPage(
                page: page(currentUser: signedInAdmin), activeCourse: course, displayGroups: groups,
                hasAny: !groups.isEmpty, slipDaySummary: slip
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "IndexPage",
            archetype: .plainStudentPage,
            renders: [
                render(nil, [], slip: nil),
                render(studentCourse, [], slip: "Slip days: 1 of 2 remaining."),
                render(studentCourse, dashboardGroups, slip: nil),
            ]
        )
    }

    static var accountPage: ElementaryPageFixture {
        let spec = AvatarSpec.drawn(fromSeed: 3)
        func render(
            staff: Bool, enrolled: [AccountCourseRow], available: [AccountCourseRow], status: String,
            github: (show: Bool, login: String?), notices: (String?, String?, String?),
            flash: FlashMessages = FlashMessages()
        ) -> String {
            AccountPage(
                page: page(currentUser: signedInAdmin), flash: flash, username: "ada",
                preferredName: staff ? nil : "Ada", identityName: staff ? "ada" : "Ada Lovelace",
                identitySecondary: staff ? nil : "ada", avatar: avatar(3),
                avatarPicker: AvatarPickerContext(for: spec, isStaff: staff), avatarInvalid: !staff,
                studentID: staff ? nil : "20123456", email: staff ? nil : "ada@example.com",
                enrolledCourses: enrolled, availableCourses: available, error: notices.0, exportStatus: status,
                exportRequestedAtDisplay: "Oct 1, 10:00", exportCompletedAtDisplay: "Oct 1, 10:05",
                exportCanRequest: status != "pending", exportNotice: notices.1, exportError: notices.2,
                showGitHub: github.show, githubLogin: github.login
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AccountPage",
            archetype: .plainStudentPage,
            renders: [
                render(
                    staff: true, enrolled: [], available: [], status: "none", github: (false, nil),
                    notices: (nil, nil, nil)),
                render(
                    staff: false, enrolled: accountEnrolledCourses, available: accountAvailableCourses,
                    status: "pending", github: (true, nil), notices: ("invalid", "started", "rate_limited"),
                    flash: FlashMessages(success: "Chickadee saved.")),
                render(
                    staff: false, enrolled: accountEnrolledCourses, available: [], status: "complete",
                    github: (true, "ada-gh"), notices: (nil, "in_progress", "not_ready")),
                render(
                    staff: true, enrolled: [], available: accountAvailableCourses, status: "failed",
                    github: (false, nil), notices: (nil, nil, nil)),
            ]
        )
    }

    static var submissionPage: ElementaryPageFixture {
        func render(_ options: SubmissionOptions) -> String {
            SubmissionPage(page: page(currentUser: signedInAdmin), result: submissionResult(options)).render()
        }
        // Every render here has an h2 before the section tables. A finished
        // submission with no class goals and no warnings goes from the h1
        // straight to the section h3, as the Leaf page did; the heading guard
        // would fail that render, so it is not one of these.
        return ElementaryPageFixture(
            typeName: "SubmissionPage",
            archetype: .plainStudentPage,
            renders: [
                render(SubmissionOptions()),
                render(SubmissionOptions(pending: true, extras: false)),
                render(SubmissionOptions(buildFailed: true, overridden: true)),
                render(
                    SubmissionOptions(
                        overridden: true, weighted: true, hasDelta: false, revealAvailable: false,
                        revealActive: true)),
            ]
        )
    }

    static var gitHubSubmitPage: ElementaryPageFixture {
        let chips = [
            SubmitChips(attemptNumber: 1, deadlineText: nil, deadlineISO: nil),
            SubmitChips(attemptNumber: 4, deadlineText: "Oct 1, 10:00", deadlineISO: "2026-10-01T14:00:00Z"),
        ]
        return ElementaryPageFixture(
            typeName: "GitHubSubmitPage",
            archetype: .plainStudentPage,
            renders: gitHubStates.enumerated().map { index, state in
                GitHubSubmitPage(
                    page: page(currentUser: signedInAdmin),
                    flash: FlashMessages(success: index == 3 ? "Your course repository is ready." : nil),
                    testSetupID: "ts-1", assignmentTitle: "Lab <1>", chips: chips[index % 2], state: state
                ).render()
            }
        )
    }

    static var assignmentFeedbackPage: ElementaryPageFixture {
        let prompts = [
            FeedbackReviewText(index: 1, paragraphs: ["Explain <why>.", "Use evidence."]),
            FeedbackReviewText(index: 2, paragraphs: ["Reflect."]),
        ]
        func render(gatesOpen: Bool, prompts: [FeedbackReviewText], rows: [FeedbackReviewRow]) -> String {
            AssignmentFeedbackPage(
                page: page(currentUser: signedInAdmin),
                flash: FlashMessages(success: rows.isEmpty ? nil : "Draft for Hazy Cedar saved"),
                assignmentID: "abc123", assignmentTitle: "Lab <1>", gatesOpen: gatesOpen, prompts: prompts,
                rows: rows, reviewCount: rows.filter(\.needsReview).count, maxDraftLength: 4000
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AssignmentFeedbackPage",
            archetype: .titlebarPage,
            renders: [
                render(gatesOpen: false, prompts: [], rows: []),
                render(gatesOpen: true, prompts: prompts, rows: feedbackRows),
            ]
        )
    }
}
