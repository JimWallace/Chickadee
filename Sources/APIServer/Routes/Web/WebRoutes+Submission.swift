// APIServer/Routes/Web/WebRoutes+Submission.swift
//
// Submission-related handlers and helpers for WebRoutes.
// Extracted from WebRoutes.swift — no behaviour changes.
//
// The result-presentation pipeline (`processDisplayResult`,
// `buildSectionedOutcomes`, the support structs, and the free helpers
// `groupOutcomesBySection` / `buildHintByFilename` / `loadClassGoalViews`)
// lives in SubmissionResultPresenter.swift.

import Core
import Elementary
import Fluent
import Foundation
import NIOFoundationCompat
import Vapor

/// The badges one graded submission earns by itself: the per-submission
/// badges and the authored individual badges.  The submission page, the
/// student dashboard and the staff per-student page all call this, so a
/// badge shows on all three pages or on none (#2020).  Class-wide badges are
/// appended by each caller.
///
/// Every badge reads `context.gradePercent`, the raw autograded grade.  A
/// class-goal bonus is extra credit for the class, not a part of this
/// submission's result, so it never earns a badge.
func badgesEarnedBySubmission(
    _ context: BadgeContext,
    props: TestProperties?,
    standings: (standing: Int, matchesWon: Int)? = nil
) -> [AchievementBadge] {
    AchievementBadge.forSubmission(
        context,
        achievements: BuiltInAchievements.manifestPerSubmission(props: props),
        disabled: Set(props?.disabledBuiltInAwardIDs ?? []))
        + earnedIndividualBadges(
            props: props,
            gradePercent: context.gradePercent,
            outcomes: context.outcomes,
            standings: standings)
}

/// The class-record badges one submission holds, resolved against the
/// manifest so a custom or renamed record shows its authored name.
func classRecordBadges(
    _ classAchievements: [APIClassAchievement], props: TestProperties?
) -> [AchievementBadge] {
    let disabled = Set(props?.disabledBuiltInAwardIDs ?? [])
    return classAchievements.compactMap {
        AchievementBadge.forClassAchievement(
            $0.achievementID,
            manifestAchievements: props?.achievements ?? [],
            disabled: disabled)
    }
}

/// The extensions a submission to this assignment may carry.
///
/// This used to union EVERY `AssignmentLanguage`'s extensions, on the reasoning
/// that a browser treats `accept` as a hint so "breadth costs nothing".  That is
/// true of the file picker and false of the student: a Racket assignment offered
/// `.py`, `.r`, `.lua` and `.m` beside `.rkt`, and the page never said which
/// language it wanted.  Now that a wrong type is REJECTED (client-side as a
/// courtesy, server-side as the gate), breadth costs the student a rejected
/// upload, so the list is the assignment's own.
///
/// `zip` is always accepted — it is the documented way to submit several files
/// at once — and `ipynb` unless the assignment is upload-only, which is exactly
/// the case with no notebook workflow.  The full union survives as the fallback
/// for an assignment that declares no language, where guessing would be worse
/// than breadth.  `requiredFiles` contribute their own extensions so a lab whose
/// files no language claims still accepts them.
func submissionAcceptedExtensions(manifest: TestProperties?) -> [String] {
    var extensions: Set<String> = ["zip"]
    if manifest?.effectiveSubmissionMode != .uploadOnly {
        extensions.insert("ipynb")
    }
    if let language = manifest?.language {
        extensions.formUnion(language.scriptExtensions)
    } else {
        for language in AssignmentLanguage.allCases {
            extensions.formUnion(language.scriptExtensions)
        }
    }
    for file in manifest?.requiredFiles ?? [] {
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        if !ext.isEmpty {
            extensions.insert(ext)
        }
    }
    return extensions.sorted()
}

/// The same set as the `accept` attribute for the file input.
func submissionAcceptAttribute(manifest: TestProperties?) -> String {
    submissionAcceptedExtensions(manifest: manifest).map { ".\($0)" }.joined(separator: ",")
}

/// One sentence under the drop zone naming what this assignment takes, because
/// an `accept` attribute is invisible until the picker opens and says nothing at
/// all to a drag-and-drop.  Chrome is not prose: one sentence, no more.
func submissionAcceptHintText(manifest: TestProperties?) -> String {
    let list = submissionAcceptedExtensions(manifest: manifest).map { ".\($0)" }
    let joined: String = {
        guard let last = list.last else { return "" }
        guard list.count > 1 else { return last }
        return list.dropLast().joined(separator: ", ") + " or " + last
    }()
    if let language = manifest?.language {
        return "\(language.displayName) assignment — accepts \(joined)."
    }
    return "Accepts \(joined)."
}

/// Whether an uploaded filename carries one of this assignment's accepted
/// extensions.  Shared by the server gate and the tests; the page's client-side
/// check reads the same list off the input's `accept` attribute, so there is one
/// source for what is accepted.
func submissionFilenameIsAccepted(_ filename: String, manifest: TestProperties?) -> Bool {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    guard !ext.isEmpty else { return true }
    return submissionAcceptedExtensions(manifest: manifest).contains(ext)
}

/// The refusal a student sees, in the same words the page's hint uses.
func submissionRejectionMessage(manifest: TestProperties?) -> String {
    "That file type is not accepted. " + submissionAcceptHintText(manifest: manifest)
}

extension WebRoutes {

    // MARK: - GET /testsetups/:id/submit

    @Sendable
    func submitForm(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw AppError.notFound(resource: "Assignment")
        }
        // Block cross-tenant info disclosure: an authenticated student
        // shouldn't be able to learn that a setupID exists in a course
        // they aren't enrolled in, nor see its assignment title.
        try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
        // Browser-graded assignments are submitted from the notebook page, not this form.
        let manifestData = Data(setup.manifest.utf8)
        let manifest = decodeManifest(from: manifestData)
        if manifest?.effectiveGradingMode == .browser {
            return req.redirect(to: "/testsetups/\(setupID)/notebook")
        }
        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        // Mirror the notebook page's closed-assignment gate: a student who has
        // never opened this (now-closed) upload-mode assignment is sent to
        // their dashboard rather than shown an upload form they cannot submit.
        if let userID = user.id, let assignment {
            let isClosed = !(try await isAssignmentEffectivelyOpen(assignment, for: user, req: req))
            if let redirect = try await req.closedAssignmentRedirect(
                user: user, userID: userID, assignment: assignment, isClosed: isClosed)
            {
                return redirect
            }
            // As on the notebook page: deal a class composite's slot on first
            // open inside its session window. Staff are never dealt one.
            if !isClosed, !(try await req.cachedIsCourseStaff(user, inCourse: setup.courseID)) {
                await CompositeSlots.dealOnOpen(
                    setup: setup, assignment: assignment, userID: userID, on: req.db)
            }
        }
        let requiredFiles = manifest?.requiredFiles ?? []
        let chips = try await SubmitChips.make(setupID: setupID, assignment: assignment, user: user, on: req.db)
        let aiFeedbackNotice =
            if let assignment { try await ReflectionFeedbackService.gatesOpen(assignment, on: req.db) } else { false }
        let githubSubmitURL =
            try await GitHubSubmissionOffer.isOffered(setup: setup, on: req.db)
            ? "/testsetups/\(setupID)/github" : nil
        let dataPageHref = try await Self.dataPageHref(manifest: manifest, courseID: setup.courseID, on: req.db)
        return try await HTMLResponse {
            SubmitPage(
                page: PageRequestContext(request: req),
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                acceptAttribute: submissionAcceptAttribute(manifest: manifest),
                acceptHintText: submissionAcceptHintText(manifest: manifest),
                errorText: req.query[String.self, at: "error"] == "filetype"
                    ? submissionRejectionMessage(manifest: manifest) : nil,
                requiredFilesText: requiredFiles.isEmpty
                    ? nil : requiredFiles.joined(separator: ", "),
                chips: chips,
                githubSubmitURL: githubSubmitURL,
                aiFeedbackNotice: aiFeedbackNotice,
                datasets: (manifest?.datasets ?? []).map { SubmitDatasetLink(spec: $0, setupID: setupID) },
                dataPageHref: dataPageHref
            )
        }.encodeResponse(for: req)
    }

    /// The course Data page, when a dataset of `manifest` comes from the
    /// course library and is published there.
    private static func dataPageHref(
        manifest: TestProperties?, courseID: UUID, on db: any Database
    ) async throws -> String? {
        let slugs = Set((manifest?.datasets ?? []).compactMap(\.source?.slug))
        guard !slugs.isEmpty, let course = try await APICourse.find(courseID, on: db) else { return nil }
        let published = try await CourseDatasetService.hasPublished(courseID: courseID, slugs: slugs, on: db)
        return published ? "/data/\(urlEncode(course.urlKey))" : nil
    }

    // MARK: - POST /testsetups/:id/submit

    @Sendable
    func createSubmission(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw AppError.notFound(resource: "Assignment")
        }

        // Browser-graded assignments must be submitted from the notebook page.
        let manifestData = Data(setup.manifest.utf8)
        let manifest = decodeManifest(from: manifestData)
        if manifest?.effectiveGradingMode == .browser {
            return req.redirect(to: "/testsetups/\(setupID)/notebook")
        }

        _ = try await requireOpenStudentAssignment(
            for: setupID, user: user, gate: .submission, on: req)

        let body = try await req.decodeContent(SubmitFormBody.self)

        // The file-type gate. The page rejects a wrong type client-side as a
        // courtesy, but that is a convenience, not a control: a direct POST
        // bypasses it entirely, and before this the upload was simply stored
        // with whatever extension it arrived with and handed to the runner,
        // where a Racket assignment fed a .py failed as a broken test script.
        // An empty filename is left to the existing content sniffing rather
        // than refused, so a legitimate upload never dies on a missing header.
        if let uploaded = body.files.filename.isEmpty ? nil : body.files.filename,
            !submissionFilenameIsAccepted(uploaded, manifest: manifest)
        {
            return req.redirect(to: "/testsetups/\(setupID)/submit?error=filetype")
        }
        let intake = SubmissionIntake(req: req)
        let subID = intake.submissionID

        // Decode the uploaded bytes. Vapor's File type captures the original
        // filename from the multipart Content-Disposition header automatically.
        let fileData = Data(body.files.data.readableBytesView)
        let uploadFilename = body.files.filename.isEmpty ? nil : body.files.filename

        // Detect whether the upload is a zip by checking PK magic bytes.
        let isZip = fileData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
        let storedExt =
            isZip ? "zip" : inferredRawSubmissionExtension(data: fileData, uploadFilename: uploadFilename)
        let fallbackFilename = isZip ? nil : (uploadFilename ?? "submission.\(storedExt)")

        try await intake.accept(
            setup: setup, owner: user,
            artifact: .bytes(fileData, fileExtension: storedExt),
            filename: fallbackFilename, status: .pending)
        return req.redirect(to: "/submissions/\(subID)")
    }

    // MARK: - GET /testsetups/:id/history

    @Sendable
    func submissionHistoryPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw AppError.unauthenticated }
        guard
            let setupID = req.parameters.get("testSetupID"),
            try await APITestSetup.find(setupID, on: req.db) != nil
        else {
            throw AppError.notFound(resource: "Assignment")
        }

        let fmt = waterlooDateTimeFormatter()

        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        let title = assignment?.title ?? setupID

        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()

        // The same "highest grade wins" fold, and the same row builder, as the
        // two staff history pages (#1709): a student and their TA read one grade.
        let bestPercentBySubmissionID = try await bestGradePercentBySubmissionID(
            for: submissions.compactMap(\.id), on: req.db)
        // No source disagreement on the student's own page: it is a staff
        // signal (docs/grading-integrity.md, D8).
        let historyRows = assignmentSubmissionHistoryRows(
            submissions: submissions, bestPercentBySubmissionID: bestPercentBySubmissionID,
            disagreementBySubmissionID: [:], fmt: fmt)

        let rows = zip(submissions, historyRows).map { submission, history -> SubmissionHistoryRow in
            let subID = history.submissionID
            let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
            let nameExt = (submission.filename ?? "").lowercased()
            let canOpenInNotebook = pathExt == "ipynb" || nameExt.hasSuffix(".ipynb")
            let openInNotebookURL =
                canOpenInNotebook
                ? "/testsetups/\(setupID)/notebook?submissionID=\(subID)"
                : nil
            return SubmissionHistoryRow(
                history: history,
                submissionFilename: submission.filename,
                canOpenInNotebook: canOpenInNotebook,
                openInNotebookURL: openInNotebookURL
            )
        }

        return try await HTMLResponse {
            SubmissionHistoryPage(page: PageRequestContext(request: req), assignmentTitle: title, rows: rows)
        }.encodeResponse(for: req)
    }

    // MARK: - GET /submissions/:id

    @Sendable
    func submissionPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        guard let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else { throw AppError.notFound(resource: "Submission") }

        // Per-course staff (TA+ or admin) see instructor-level detail for this
        // submission's course; everyone else may view only their own
        // submission (#417 Slice G — was the global `user.isInstructor`).
        let (setup, isStaff) = try await submissionSetupAndStaff(req: req, user: user, submission: submission)
        guard isStaff || submission.userID == user.id else {
            throw AppError.forbidden(action: "view this submission")
        }

        // Two representations, one query, as on every polled page:
        // `?fragment=state` renders the pending band's contents from the same
        // view the page rendered inline, for `table-poll.js` (#3007).
        if req.query[String.self, at: "fragment"] == "state" {
            return Response.pollFragment(
                html: SubmissionStateRegion(status: submission.statusValue).render(), for: req)
        }

        // Fetch the assignment for deadline-based output gating.
        let submissionAssignment = try await assignmentByTestSetupID(submission.testSetupID, on: req.db)
        let setupProps = setup?.decodedManifest()
        // Students see public + release rows itemized (release output is gated
        // on the deadline); secret is itemized only after the student spends
        // their secret-reveal token (toggle + spend row, see
        // `SecretRevealState`).  The grade itself spans every tier — see
        // `processDisplayResult` — so it is stable across the deadline and
        // matches the dashboard.
        //
        // Release *output* is gated on the *effective* deadline — the later of
        // the assignment due date and the viewer's own per-student extension —
        // so a student with an active extension keeps the hidden release output
        // redacted until their extended window closes.  A non-instructor may
        // only view their own submission (guarded above), so `user` is the
        // submission owner (which is why resolving the reveal state by viewer
        // ID is correct); instructors see release output regardless.
        let reveal = try await SecretRevealState.resolve(
            assignment: submissionAssignment, userID: user.id, isStaff: isStaff, on: req.db)
        let itemized = itemizedTiers(isStaff: isStaff, secretRevealed: reveal.revealed)
        let studentReveal = try await studentRevealState(
            isStaff: isStaff, assignment: submissionAssignment, user: user, on: req.db)
        let releaseOutput = releaseOutputVisible(isStaff: isStaff, effectiveDueAt: studentReveal.releaseDeadline)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (displayResult, displayCollection) = try await loadDisplayResultAndCollection(
            subID: subID, decoder: decoder, on: req.db)
        let priorAttempt = try await loadPriorAttemptDelta(
            submission: submission, decoder: decoder, on: req.db)
        let manifestDisplay = manifestDisplayData(from: setupProps)

        var processed = ProcessedCollection.empty
        if let result = displayResult {
            processed = processDisplayResult(
                result: result,
                collection: displayCollection,
                viewer: SubmissionViewer(
                    user: user, isStaff: isStaff, itemizedTiers: itemized,
                    releaseOutputVisible: releaseOutput,
                    secretRevealed: reveal.revealed),
                submission: submission,
                priorAttempt: priorAttempt,
                manifestDisplay: manifestDisplay
            )
        }

        // The class goals' snapshots feed both the bonus and the goal panel,
        // so they are read once.
        let classGoalAchievements = setupProps?.achievements.filter(\.isClassGoal) ?? []
        let goalSnapshots = try await classGoalSnapshots(
            goals: classGoalAchievements, props: setupProps, submission: submission,
            assignment: submissionAssignment, on: req.db)
        applyClassGoalBonus(to: &processed, goals: classGoalAchievements, snapshots: goalSnapshots)

        let (badges, grantedItems) = try await submissionBadges(
            req: req, submission: submission, displayCollection: displayCollection, setupProps: setupProps,
            processed: processed,
            awardRecipient: awardRecipient(user, submission, isStaff: isStaff, course: studentReveal.course))

        let sectionedOutcomes = buildSectionedOutcomes(
            outcomes: processed.outcomes,
            secretOutcomes: processed.secretOutcomes,
            manifestEntries: manifestDisplay.entries,
            manifestSections: manifestDisplay.sections,
            allowedTiers: itemized,
            // Same weighting test the visible rows use, so a masked row prices
            // its points exactly as a named one would.
            weighted: displayCollection.map { $0.totalPoints != $0.totalTests } ?? false
        )

        let currentAttempt = submission.attemptNumber ?? 1
        let hasDelta = !priorAttempt.outcomeMap.isEmpty
        let deltaHeaderText = buildDeltaHeaderText(
            outcomes: processed.outcomes,
            hasDelta: hasDelta,
            currentAttempt: currentAttempt
        )

        // An instructor override is the student's effective grade for the
        // assignment; surface it above this attempt's autograded breakdown.
        let overrideGradePercent = try await submitterOverridePercent(submission, on: req.db)

        let links = studentFacingLinks(
            submission: submission, assignment: submissionAssignment, props: setupProps,
            user: user, isStaff: isStaff, solutionVisible: studentReveal.solutionVisible)

        var ctx = buildSubmissionContext(
            subID: subID,
            submission: submission,
            processed: processed,
            sectionedOutcomes: sectionedOutcomes,
            decorations: SubmissionDecorations(
                badges: badges,
                overrideGradePercent: overrideGradePercent,
                classGoals: classGoalViews(goals: classGoalAchievements, snapshots: goalSnapshots),
                secretReveal: SecretRevealBanner(
                    available: reveal.enabled && !reveal.spent && !isStaff
                        && hasSecretTierTests(setupProps),
                    active: reveal.revealed),
                solutionURL: links.solutionURL,
                leaderboardURL: links.leaderboardURL,
                // Staff only, and only for student work with a published
                // assignment to link back through.
                diffURL: (isStaff && submission.kind == APISubmission.Kind.student)
                    ? submissionAssignment.map {
                        "/instructor/\($0.publicID)/submissions/\(subID)/diff"
                    } : nil,
                releasedFeedback: try await ReflectionFeedbackService.releasedFeedback(
                    for: submission, assignment: submissionAssignment, on: req.db),
                compositeTile: try await CompositeTilePanel.make(
                    for: submission, displayCollection, setupProps, submissionAssignment, viewer: user, on: req.db)
            ),
            delta: DeltaBanner(hasDelta: hasDelta, headerText: deltaHeaderText)
        )
        ctx.assignmentTitle = submissionAssignment?.title
        if let submittedAt = submission.submittedAt {
            ctx.submittedAtISO = submittedAt.formatted(.iso8601)
            ctx.submittedAtText = waterlooDateTimeFormatter().string(from: submittedAt)
        }
        let back = submissionBackLink(
            submission: submission, assignment: submissionAssignment, isStaff: isStaff, viewer: user)
        ctx.backURL = back?.url
        ctx.backLabel = back?.label
        ctx.bird = try await submissionBird(
            for: user, submission: submission, context: ctx, isStaff: isStaff,
            result: OwnResult(graded: displayCollection, granted: grantedItems), req: req)
        let page = PageRequestContext(request: req)
        let flash = SpareFlash.messages(for: req.query[String.self, at: "spare"])
        return try await HTMLResponse { SubmissionPage(page: page, result: ctx, flash: flash) }.encodeResponse(for: req)
    }

    /// The result page's way back (#3007, findings 3 and 13): the viewer's
    /// own history of the assignment, or for staff the assignment's
    /// submissions page. Nil when the submission has no published assignment.
    private func submissionBackLink(
        submission: APISubmission, assignment: APIAssignment?, isStaff: Bool, viewer: APIUser
    ) -> (url: String, label: String)? {
        guard let assignment else { return nil }
        if submission.kind == APISubmission.Kind.student, submission.userID == viewer.id {
            return ("/testsetups/\(submission.testSetupID)/history", "Submission history")
        }
        guard isStaff else { return nil }
        return ("/instructor/\(assignment.publicID)/submissions", "All submissions")
    }

    /// The instructor's grade override for the submitter, if any.
    private func submitterOverridePercent(_ submission: APISubmission, on db: any Database) async throws -> Int? {
        guard let userID = submission.userID else { return nil }
        return try await gradeOverridePercent(setupID: submission.testSetupID, userID: userID, on: db)
    }

    /// What the student's own bird reacts to: the graded result the page
    /// shows, and the items this page's achievements just granted
    /// (docs/achievement-rewards.md, S2).
    private struct OwnResult {
        let graded: TestOutcomeCollection?
        let granted: [AchievementAwardStore.GrantedItem]
    }

    /// The bird of the student who made this submission
    /// (`SubmissionContext.bird`). The student sees their own bird reacting
    /// to `context`, with the celebration the page plays for the `graded`
    /// result (docs/result-celebration.md). Staff see the student's bird as
    /// it is stored: no reaction and no celebration.
    private func submissionBird(
        for user: APIUser, submission: APISubmission, context: SubmissionContext, isStaff: Bool,
        result: OwnResult, req: Request
    ) async throws -> SubmissionBird? {
        let db = req.db
        guard submission.kind == APISubmission.Kind.student, let submitterID = submission.userID else { return nil }
        if user.id == submitterID {
            return try await ownBird(
                for: user, submission: submission, context: context, isStaff: isStaff, result: result, req: req)
        }
        guard isStaff, let submitter = try await APIUser.find(submitterID, on: db) else { return nil }
        let spec = try await AvatarStore.ensureSpec(for: submitter, on: db)
        // The bird is the student's in their role here; a student-kind
        // submission is a student's work, so it wears the student's own ring.
        return SubmissionBird(
            avatar: AvatarPresentation(for: spec, size: .result, accessibility: .decorative, isStaff: false),
            reaction: .none)
    }

    /// The student's own bird on their own result. An instructor's grade
    /// override plays no celebration, because the page shows that grade
    /// first.
    private func ownBird(
        for user: APIUser, submission: APISubmission, context: SubmissionContext, isStaff: Bool,
        result: OwnResult, req: Request
    ) async throws -> SubmissionBird {
        let graded = result.graded
        let db = req.db
        let spec = try await AvatarStore.ensureSpec(for: user, on: db)
        let reaction = AvatarReaction(
            passCount: context.passCount, totalTests: context.totalTests,
            buildFailed: context.buildFailed, isPending: context.isPending)
        var celebration: SubmissionCelebration?
        let gradeIsOverridden = context.gradeIsOverridden
        let percent = graded.flatMap(gradePercent(from:))
        if !context.isPending, !context.buildFailed, !gradeIsOverridden, let percent {
            let history = try await CelebrationHistory.load(for: submission, on: db)
            if history.isLatest,
                let state = ResultCelebration(
                    percent: percent, previousPercent: history.previousPercent,
                    earlierBestPercent: history.bestPercent)
            {
                celebration = SubmissionCelebration(
                    state: state, gradeTo: percent, gradeFrom: history.previousPercent ?? 0,
                    passCount: context.passCount, totalTests: context.totalTests)
            }
        }
        let earned =
            context.isPending
            ? nil : try await earnedItem(for: user, wearing: spec, isStaff: isStaff, granted: result.granted, req: req)
        return SubmissionBird(
            avatar: AvatarPresentation(
                for: reaction.applied(to: spec), size: .result, accessibility: .decorative, isStaff: isStaff),
            reaction: reaction, isOwn: true, celebration: celebration,
            isFullMarks: percent == 100 && !gradeIsOverridden, earned: earned)
    }

    /// The first item that this page load grants, for the Earned toast
    /// (docs/result-celebration.md, J2). The grant runs here, off the grading
    /// path, as on the account page. A cosmetic never fails the page: when a
    /// lookup fails, the page shows no toast, and a failed grant grants again
    /// on the next load. Course staff cannot choose a ring, so a ring is
    /// never theirs to wear.
    ///
    /// `granted` holds the items this page's achievements just granted
    /// (docs/achievement-rewards.md, S2). The toast shows one of those first,
    /// with the achievement's name, since the instructor chose it for this
    /// assignment; the rule items it grants stay stored and show on the next
    /// load or on the account page.
    private func earnedItem(
        for user: APIUser, wearing spec: AvatarSpec, isStaff: Bool,
        granted achievementItems: [AchievementAwardStore.GrantedItem], req: Request
    ) async throws -> SubmissionEarnedItem? {
        let db = req.db
        let userID = try user.requireID()
        // The rule grant runs on every load, so a rule item is stored even
        // when an achievement's item takes the toast.
        let ruleItems =
            (try? await WardrobeUnlockStore.grantNew(
                for: userID, on: db, checks: req.application.wardrobeGrantChecks)) ?? []
        // The staff lookup only matters when something was granted, which is
        // rare, so it runs after the grant.
        guard !(achievementItems.isEmpty && ruleItems.isEmpty),
            let staff = try? await AvatarStore.courseStaff(among: [userID], on: db)
        else {
            return nil
        }
        let isCourseStaff = !staff.isEmpty
        func wearable(_ item: WardrobeItem) -> Bool { !(isCourseStaff && item.slot == .border) }
        if let granted = achievementItems.first(where: { wearable($0.item) }) {
            return SubmissionEarnedItem(granted.item, wearing: spec, isStaff: isStaff, grantedBy: granted.label)
        }
        guard let item = ruleItems.first(where: wearable) else { return nil }
        return SubmissionEarnedItem(item, wearing: spec, isStaff: isStaff)
    }

    // MARK: - submissionPage helpers

    /// The submission's test setup, read ONCE, and whether `user` is staff
    /// (TA+ or admin) of its course. The page's helpers (manifest display
    /// data, class-goal bonus, badges, class-goal views) all read the
    /// setup's decoded manifest, which each used to re-fetch and re-decode
    /// independently (#1128). A missing setup (hence course) leaves the
    /// viewer non-staff, as `isSubmissionStaff` does (#417 Slice G).
    func submissionSetupAndStaff(
        req: Request, user: APIUser, submission: APISubmission
    ) async throws -> (setup: APITestSetup?, isStaff: Bool) {
        guard let setup = try await APITestSetup.find(submission.testSetupID, on: req.db) else {
            return (nil, false)
        }
        return (setup, try await req.cachedIsCourseStaff(user, inCourse: setup.courseID))
    }

    /// A student viewer's reveal state on their own result: the assignment's
    /// course, the deadline that gates release-tier output, and whether the
    /// solution link shows. The two gates read the course, the extension
    /// and the slip-day state once (`studentRevealGates`). Staff see release
    /// output regardless and reach the solution through the workbench, so
    /// for them, and with no assignment, nothing is read.
    private struct StudentRevealState {
        var course: APICourse?
        var releaseDeadline: Date?
        var solutionVisible = false
    }

    private func studentRevealState(
        isStaff: Bool, assignment: APIAssignment?, user: APIUser, on db: any Database
    ) async throws -> StudentRevealState {
        guard !isStaff, let assignment else { return StudentRevealState() }
        let course = try await APICourse.find(assignment.courseID, on: db)
        let gates = try await studentRevealGates(for: assignment, course: course, user: user, on: db)
        return StudentRevealState(
            course: course, releaseDeadline: gates.releaseDeadline, solutionVisible: gates.solutionVisible)
    }

    /// The snapshots of `goals` (the manifest's class goals) that apply to
    /// the submitter (`LabGoalGroups.snapshots`), read once for both the
    /// bonus and the goal panel. No class goals, no read.
    private func classGoalSnapshots(
        goals: [Achievement], props: TestProperties?, submission: APISubmission, assignment: APIAssignment?,
        on db: any Database
    ) async throws -> [String: any ClassGoalSnapshot] {
        guard let props, !goals.isEmpty else { return [:] }
        return try await LabGoalGroups.snapshots(
            testSetupID: submission.testSetupID, props: props, userID: submission.userID,
            assignment: assignment, on: db)
    }

    /// The two optional links a student reviewing their results may follow.
    ///
    /// The solution link is for the owner-student once their reveal moment
    /// has arrived (`solutionVisibleToStudent` — the same gate the serving
    /// routes enforce); staff reach the solution through the workbench, and a
    /// staff view of a student's submission should not read as the student's
    /// page anyway. The leaderboard link appears when the viewer may open it:
    /// staff always, a student once the instructor has published it.
    /// `solutionVisible` is the student's reveal gate, already resolved
    /// (`studentRevealGates`).
    private func studentFacingLinks(
        submission: APISubmission, assignment: APIAssignment?, props: TestProperties?,
        user: APIUser, isStaff: Bool, solutionVisible: Bool
    ) -> (solutionURL: String?, leaderboardURL: String?) {
        var solutionURL: String?
        if !isStaff, submission.userID == user.id, assignment != nil, solutionVisible {
            solutionURL =
                props?.effectiveSubmissionMode == .uploadOnly
                ? "/testsetups/\(submission.testSetupID)/solution/download"
                : "/testsetups/\(submission.testSetupID)/notebook?file=solution"
        }
        let leaderboardURL = props?.activity?.leaderboardPath(
            testSetupID: submission.testSetupID, viewerIsStaff: isStaff)
        return (solutionURL, leaderboardURL)
    }

    /// Class-goal bonus: true extra credit on the autograded grade, so a
    /// student already at full marks reads above 100% (no-op unless the
    /// assignment has a points-rewarded class goal).
    /// `snapshots` are the class goals' snapshots that apply to the
    /// submitter (`LabGoalGroups.snapshots`), already read.
    private func applyClassGoalBonus(
        to processed: inout ProcessedCollection,
        goals: [Achievement],
        snapshots: [String: any ClassGoalSnapshot]
    ) {
        guard processed.totalPoints > 0 else { return }
        let bonus = classGoalBonusPoints(goals: goals, snapshots: snapshots)
        guard bonus > 0 else { return }
        let bonused = earnedWithClassGoalBonus(
            earned: processed.rawEarnedPoints,
            total: Double(processed.totalPoints),
            bonus: bonus)
        processed.gradePercent =
            GradePercent.of(earned: bonused, total: Double(processed.totalPoints)) ?? 0
        processed.earnedPoints = formatPoints(bonused)
    }

    /// The student whose award ledger this page view writes to, or nil. Only
    /// the student's own view of their own student submission writes
    /// (docs/achievement-rewards.md, S1): a staff view writes nothing, so
    /// reading a student's work never changes the student's record.
    /// `course` is the assignment's course, which the page read for the
    /// student's reveal gates (nil when there is no assignment): the course
    /// whose achievements the view grants.
    private func awardRecipient(
        _ viewer: APIUser, _ submission: APISubmission, isStaff: Bool, course: APICourse?
    ) -> AwardRecipient? {
        guard !isStaff, submission.kind == APISubmission.Kind.student,
            let viewerID = viewer.id, submission.userID == viewerID
        else { return nil }
        return AwardRecipient(userID: viewerID, course: course)
    }

    /// The student whose ledger a page view writes to, and the course of
    /// the assignment, for the course achievements.
    private struct AwardRecipient {
        let userID: UUID
        let course: APICourse?
    }

    /// Assembles the badge strip for one submission: the badges its own
    /// result earns (`badgesEarnedBySubmission`, the same call the dashboard
    /// and the staff per-student page make), then the class-wide record
    /// badges this submission holds.  Individual badges read every tier, so a
    /// secret-test badge works without revealing the test.  A submission with
    /// no result yet earns none.  The earned badges are stored in
    /// `awardRecipient`'s award ledger, when there is one; a failed write
    /// does not stop the page.
    private func submissionBadges(
        req: Request,
        submission: APISubmission,
        displayCollection: TestOutcomeCollection?,
        setupProps: TestProperties?,
        processed: ProcessedCollection,
        awardRecipient: AwardRecipient?
    ) async throws -> (badges: [AchievementBadge], granted: [AchievementAwardStore.GrantedItem]) {
        let subID = try submission.requireID()
        let classAchievements = try await APIClassAchievement.query(on: req.db)
            .filter(\.$submissionID == subID)
            .all()
        // The standings are the student's CURRENT place, from their latest
        // submission — read only on a standings activity, so every other
        // page pays no query.
        var standings: (standing: Int, matchesWon: Int)?
        if setupProps?.activity?.kind.aggregation == .standings, let userID = submission.userID {
            standings = try await standingSignals(testSetupID: submission.testSetupID, userID: userID, on: req.db)
        }
        // `badgeContext` holds the raw grade; `processed.gradePercent` may
        // carry a class-goal bonus, which never earns a badge (#2020).
        let earned =
            displayCollection == nil
            ? [] : badgesEarnedBySubmission(processed.badgeContext, props: setupProps, standings: standings)
        var granted: [AchievementAwardStore.GrantedItem] = []
        if let awardRecipient {
            // A wardrobe achievement is hidden until earned
            // (docs/achievement-rewards.md, decision 5): it is never a badge
            // here, and its item is granted the first time it is satisfied.
            // Not while a retest is pending: the page shows no toast then, and
            // an item granted with no toast would never get one.
            let isPending = submission.statusValue == .pending || submission.statusValue == .assigned
            if displayCollection != nil, !isPending {
                let rewards = earnedWardrobeRewards(processed.badgeContext, props: setupProps, standings: standings)
                if !rewards.isEmpty {
                    granted = await AchievementAwardStore.grantWardrobeRewardsOrLog(
                        rewards, testSetupID: submission.testSetupID, submissionID: subID,
                        earnedBy: awardRecipient.userID, on: req.db, logger: req.logger)
                }
            }
            let recorded = AchievementAwardStore.Earned(
                testSetupID: submission.testSetupID, submissionID: subID, badges: earned)
            await AchievementAwardStore.recordOrLog(
                [recorded], earnedBy: awardRecipient.userID, on: req.db, logger: req.logger)
            // After the assignment's badges, so a course achievement that
            // counts them sees the ones this page just stored. No assignment,
            // no course; an archived course grants nothing.
            if let course = awardRecipient.course, !course.isArchived {
                await AchievementAwardStore.grantCourseAchievementsOrLog(
                    for: awardRecipient.userID, in: [course], on: req.db, logger: req.logger)
            }
        }
        return (earned + classRecordBadges(classAchievements, props: setupProps), granted)
    }

    /// Selects the result row to render on the submission page: the worker
    /// result is preferred (official grade); the browser result is the
    /// fallback used for in-page preview while the worker is still queued.
    private func loadPreferredDisplayResult(
        subID: String, on db: any Database
    ) async throws -> APIResult? {
        let allResults = try await APIResult.query(on: db)
            .filter(\.$submissionID == subID)
            .sort(\.$receivedAt, .descending)
            .all()
        let workerResult = allResults.first { ($0.source ?? "worker") == "worker" }
        let browserResult = allResults.first { $0.source == "browser" }
        return workerResult ?? browserResult
    }

    /// The preferred display result plus its collection, fetched from the
    /// result_collections side table and decoded ONCE (#1173) — the presenter
    /// and the individual-badge evaluation share the decoded value.
    func loadDisplayResultAndCollection(
        subID: String, decoder: JSONDecoder, on db: any Database
    ) async throws -> (APIResult?, TestOutcomeCollection?) {
        guard let result = try await loadPreferredDisplayResult(subID: subID, on: db) else {
            return (nil, nil)
        }
        guard let json = try await result.loadCollectionJSON(on: db) else {
            return (result, nil)
        }
        let collection = try? decoder.decode(TestOutcomeCollection.self, from: Data(json.utf8))
        return (result, collection)
    }

    /// Fetches the immediately-prior attempt for per-test delta display and the
    /// Comeback Kid badge.  Returns `(outcomeMap: empty, gradePercent: nil)`
    /// when there is no prior attempt or no decodable prior result.
    private func loadPriorAttemptDelta(
        submission: APISubmission, decoder: JSONDecoder, on db: any Database
    ) async throws -> PriorAttemptDelta {
        let currentAttempt = submission.attemptNumber ?? 1
        guard currentAttempt > 1, let userID = submission.userID else {
            return .empty
        }
        guard
            let priorSub = try await APISubmission.query(on: db)
                .filter(\.$testSetupID == submission.testSetupID)
                .filter(\.$userID == userID)
                .filter(\.$attemptNumber == currentAttempt - 1)
                .first(),
            let priorSubID = priorSub.id
        else {
            return .empty
        }
        let priorResults = try await APIResult.query(on: db)
            .filter(\.$submissionID == priorSubID)
            .sort(\.$receivedAt, .descending)
            .all()
        let priorResult = priorResults.first { ($0.source ?? "worker") == "worker" } ?? priorResults.first
        guard let priorResult,
            let priorJSON = try await priorResult.loadCollectionJSON(on: db),
            let priorCollection = try? decoder.decode(
                TestOutcomeCollection.self, from: Data(priorJSON.utf8))
        else {
            return .empty
        }

        var outcomeMap: [String: TestStatus] = [:]
        for o in priorCollection.outcomes {
            outcomeMap[o.testName] = o.status
        }
        let gradePercent = gradePercent(from: priorCollection)
        return PriorAttemptDelta(outcomeMap: outcomeMap, gradePercent: gradePercent)
    }

    /// Extracts from the page's already-decoded manifest (#1128):
    /// - a script/stem→displayName map so the page shows friendly names for
    ///   worker results that already use the display name directly, older
    ///   worker results where testName is the filename stem, and browser
    ///   results where testName is the full script filename;
    /// - the manifest's section list and the full `testSuites` list, so the
    ///   page can build a parallel `sectionIDPerOutcome` array.  We can't do
    ///   a name-keyed lookup because two families in different sections may
    ///   legally share case labels (v0.4.105 bug).
    private func manifestDisplayData(from props: TestProperties?) -> ManifestDisplayData {
        var displayNameMap: [String: String] = [:]
        var hintByFilename: [String: String] = [:]
        var sections: [TestSuiteSection] = []
        var entries: [TestSuiteEntry] = []
        if let props {
            sections = props.sections
            entries = props.testSuites
            for entry in props.testSuites {
                let stem = runnerScriptStem(entry.script)
                let stemKey = stem.isEmpty ? entry.script : stem
                if let displayName = entry.name,
                    !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    displayNameMap[entry.script] = displayName
                    displayNameMap[stemKey] = displayName
                }
            }
            hintByFilename = buildHintByFilename(props)
        }
        return ManifestDisplayData(
            displayNameMap: displayNameMap, hintByFilename: hintByFilename,
            failureDetailByFilename: props.map(buildFailureDetailByFilename) ?? [:],
            sections: sections, entries: entries,
            testNameAliases: props?.testNameAliases() ?? [:])
    }
}

// `SubmitFormBody` and the submission-output formatting helpers live in
// Sources/APIServer/Helpers/SubmissionOutputFormatting.swift.
