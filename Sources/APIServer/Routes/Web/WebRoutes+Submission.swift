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
import Fluent
import Foundation
import Vapor

/// The built-in badges (per-submission + class records) for one submission,
/// sourced from the manifest when seeded, else the registry minus any disabled.
/// Takes the page's already-loaded `setup` so it doesn't re-fetch the row.
/// Lifted out of `submissionPage` to keep that handler within its length budget.
func builtInBadgesForSubmission(
    badgeContext: BadgeContext,
    classAchievements: [APIClassAchievement],
    setup: APITestSetup?
) -> [AchievementBadge] {
    let disabled = setup.map { BuiltInAchievements.disabled(in: $0) } ?? []
    return AchievementBadge.forSubmission(
        badgeContext,
        achievements: BuiltInAchievements.manifestPerSubmission(in: setup),
        disabled: disabled)
        + classAchievements.compactMap {
            AchievementBadge.forClassAchievement($0.achievementID, disabled: disabled)
        }
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
            throw Abort(.notFound)
        }
        // Block cross-tenant info disclosure: an authenticated student
        // shouldn't be able to learn that a setupID exists in a course
        // they aren't enrolled in, nor see its assignment title.
        try await requireCourseEnrollment(caller: user, courseID: setup.courseID, db: req.db)
        // Browser-graded assignments are submitted from the notebook page, not this form.
        let manifestData = Data(setup.manifest.utf8)
        if let manifest = decodeManifest(from: manifestData),
            manifest.gradingMode == .browser
        {
            return req.redirect(to: "/testsetups/\(setupID)/notebook")
        }
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        // Mirror the notebook page's closed-assignment gate: a student who has
        // never opened this (now-closed) upload-mode assignment is sent to
        // their dashboard rather than shown an upload form they cannot submit.
        if let userID = user.id, let assignment {
            let isClosed = !(try await isAssignmentEffectivelyOpen(assignment, for: user, on: req.db))
            if let redirect = try await closedAssignmentGate(
                req: req, user: user, userID: userID, assignment: assignment, isClosed: isClosed)
            {
                return redirect
            }
        }
        return try await req.view.render(
            "submit",
            SubmitContext(
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                currentUser: req.currentUserContext
            )
        ).encodeResponse(for: req)
    }

    // MARK: - POST /testsetups/:id/submit

    @Sendable
    func createSubmission(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Browser-graded assignments must be submitted from the notebook page.
        let manifestData = Data(setup.manifest.utf8)
        if let manifest = decodeManifest(from: manifestData),
            manifest.gradingMode == .browser
        {
            return req.redirect(to: "/testsetups/\(setupID)/notebook")
        }

        _ = try await requireOpenStudentAssignment(for: setupID, user: user, on: req)

        let body = try req.content.decode(SubmitFormBody.self)
        let subsDir = req.application.submissionsDirectory
        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"

        // Decode the uploaded bytes. Vapor's File type captures the original
        // filename from the multipart Content-Disposition header automatically.
        let fileData = Data(body.files.data.readableBytesView)
        let uploadFilename = body.files.filename.isEmpty ? nil : body.files.filename

        // Detect whether the upload is a zip by checking PK magic bytes.
        let isZip = fileData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
        let ext: String = {
            if isZip { return "zip" }
            return inferredRawSubmissionExtension(data: fileData, uploadFilename: uploadFilename)
        }()
        let storedExt = isZip ? "zip" : ext
        let filePath = subsDir + "\(subID).\(storedExt)"
        try fileData.write(to: URL(fileURLWithPath: filePath))
        let fallbackFilename = isZip ? nil : (uploadFilename ?? "submission.\(storedExt)")

        // Attempt number is scoped to this student for this test setup,
        // assigned race-free inside one transaction (concurrent submits used
        // to share a number, corrupting the prior-attempt delta and the
        // First-Try-Perfect badge).
        let submission = APISubmission(
            id: subID,
            testSetupID: setupID,
            zipPath: filePath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            filename: fallbackFilename,
            userID: user.id,
            kind: APISubmission.Kind.student
        )
        try await saveSubmissionWithNextAttemptNumber(submission, userID: user.id, on: req.db)
        await req.application.diagnostics.recordSubmissionCreated(
            submission: submission, on: req.db, logger: req.logger
        )

        // Award Pathfinder to the first STUDENT in the class who submits.
        // Pre-v0.4.127 this gated on `classCount == 1` over student-kind
        // submissions, with no role check on the submitter — so an admin
        // or instructor testing the assignment would lock in this
        // immutable badge before any real student had a chance.  The fix
        // checks the submitter's role and uses the existence of a
        // pathfinder row directly (the unique constraint on
        // (test_setup_id, achievement_id) makes this the natural query).
        // Award only to a per-course STUDENT in this setup's course (#417 Slice
        // G2 — the global student role was retired); an admin/TA/instructor
        // testing the assignment must not lock in the immutable badge.
        if let uid = user.id,
            try await courseRole(of: uid, inCourse: setup.courseID, db: req.db) == .student
        {
            // First-to-submit records (Pathfinder) — the manifest's authored
            // ones, or the registry default, minus any the instructor disabled.
            let records = BuiltInAchievements.classRecordsForAward(
                in: setup, disabled: BuiltInAchievements.disabled(in: setup))
            for record in records where record.recordDimension == .firstToSubmit {
                let exists =
                    try await APIClassAchievement.query(on: req.db)
                    .filter(\.$testSetupID == setupID)
                    .filter(\.$achievementID == record.id)
                    .first() != nil
                if !exists {
                    try? await APIClassAchievement(
                        testSetupID: setupID, achievementID: record.id,
                        userID: uid, submissionID: subID
                    ).save(on: req.db)
                }
            }
        }

        await ensureLocalRunnerForSubmissionIfNeeded(req: req)

        return req.redirect(to: "/submissions/\(subID)")
    }

    // MARK: - GET /testsetups/:id/history

    @Sendable
    func submissionHistoryPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            try await APITestSetup.find(setupID, on: req.db) != nil
        else {
            throw Abort(.notFound)
        }

        let fmt = waterlooDateTimeFormatter()

        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let title = assignment?.title ?? setupID

        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()

        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissions.compactMap(\.id), on: req.db)

        let rows = submissions.map { submission -> SubmissionHistoryRow in
            let subID = submission.id ?? ""
            let gradeText: String
            if let result = preferredResultBySubmissionID[subID],
                let pct = result.gradePercentValue
            {
                gradeText = "\(pct)%"
            } else {
                gradeText = "—"
            }
            let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
            let nameExt = (submission.filename ?? "").lowercased()
            let canOpenInNotebook = pathExt == "ipynb" || nameExt.hasSuffix(".ipynb")
            let openInNotebookURL =
                canOpenInNotebook
                ? "/testsetups/\(setupID)/notebook?submissionID=\(subID)"
                : nil
            return SubmissionHistoryRow(
                submissionID: subID,
                attemptNumber: submission.attemptNumber ?? 1,
                status: submission.status,
                submittedAt: submission.submittedAt.map { fmt.string(from: $0) } ?? "—",
                gradeText: gradeText,
                submissionFilename: submission.filename,
                canOpenInNotebook: canOpenInNotebook,
                openInNotebookURL: openInNotebookURL
            )
        }

        return try await req.view.render(
            "submission-history",
            SubmissionHistoryContext(
                testSetupID: setupID,
                assignmentTitle: title,
                rows: rows,
                currentUser: req.currentUserContext
            ))
    }

    // MARK: - GET /submissions/:id

    @Sendable
    func submissionPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)

        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Per-course staff (TA+ or admin) see instructor-level detail for this
        // submission's course; everyone else may view only their own
        // submission (#417 Slice G — was the global `user.isInstructor`).
        let isStaff = try await isSubmissionStaff(user, submission: submission, on: req.db)
        guard isStaff || submission.userID == user.id else {
            throw Abort(.forbidden)
        }

        // Fetch the assignment for deadline-based output gating, and the test
        // setup + decoded manifest ONCE — the page's helpers (manifest display
        // data, class-goal bonus, badges, class-goal views) all read them, and
        // each used to re-fetch and re-decode independently (#1128).
        let submissionAssignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == submission.testSetupID)
            .first()
        let setup = try await APITestSetup.find(submission.testSetupID, on: req.db)
        let setupProps = setup?.decodedManifest()
        // Students see public + release rows itemized (release output is gated
        // on the deadline); secret is never itemized.  The grade itself spans
        // every tier — see `processDisplayResult` — so it is stable across the
        // deadline and matches the dashboard.
        //
        // Release *output* is gated on the *effective* deadline — the later of
        // the assignment due date and the viewer's own per-student extension —
        // so a student with an active extension keeps the hidden release output
        // redacted until their extended window closes.  A non-instructor may
        // only view their own submission (guarded above), so `user` is the
        // submission owner; instructors see release output regardless.
        let itemized = itemizedTiers(isStaff: isStaff)
        let releaseDeadline = try await releaseVisibilityDeadline(
            for: submissionAssignment, user: user, on: req.db)
        let releaseOutput = releaseOutputVisible(isStaff: isStaff, effectiveDueAt: releaseDeadline)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let displayResult = try await loadPreferredDisplayResult(subID: subID, on: req.db)
        let priorAttempt = try await loadPriorAttemptDelta(
            submission: submission, decoder: decoder, on: req.db)
        let manifestDisplay = manifestDisplayData(from: setupProps)

        var processed = ProcessedCollection.empty
        if let result = displayResult {
            processed = processDisplayResult(
                result: result,
                viewer: SubmissionViewer(
                    user: user, isStaff: isStaff, itemizedTiers: itemized,
                    releaseOutputVisible: releaseOutput),
                submission: submission,
                priorAttempt: priorAttempt,
                manifestDisplay: manifestDisplay,
                decoder: decoder
            )
        }

        // Class-goal bonus: extra credit on the autograded grade, capped at 100%
        // (no-op unless the assignment has a points-rewarded class goal).
        if processed.totalPoints > 0 {
            let bonus = try await classGoalBonusPoints(
                testSetupID: submission.testSetupID, props: setupProps, on: req.db)
            if bonus > 0 {
                let bonused = earnedWithClassGoalBonus(
                    earned: processed.rawEarnedPoints,
                    total: Double(processed.totalPoints),
                    bonus: bonus)
                processed.gradePercent = Int(
                    (bonused / Double(processed.totalPoints) * 100).rounded())
                processed.earnedPoints = formatPoints(bonused)
            }
        }

        // Append class-wide achievement badges held by this specific submission.
        let classAchievements = try await APIClassAchievement.query(on: req.db)
            .filter(\.$submissionID == subID)
            .all()
        // Authorable individual badges (threshold / test), earned per-student
        // from this submission's result (evaluated over all tiers so a
        // secret-test badge works without revealing the test).
        let individualBadges = earnedIndividualBadgesForDisplay(
            displayResult: displayResult, props: setupProps,
            gradePercent: processed.gradePercent, decoder: decoder)
        let badges =
            builtInBadgesForSubmission(
                badgeContext: processed.badgeContext,
                classAchievements: classAchievements,
                setup: setup)
            + individualBadges

        let sectionedOutcomes = buildSectionedOutcomes(
            outcomes: processed.outcomes,
            secretOutcomes: processed.secretOutcomes,
            manifestEntries: manifestDisplay.entries,
            manifestSections: manifestDisplay.sections,
            allowedTiers: itemized
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
        var overrideGradePercent: Int?
        if let submissionUserID = submission.userID {
            overrideGradePercent = try await gradeOverridePercent(
                setupID: submission.testSetupID, userID: submissionUserID, on: req.db)
        }

        let classGoals = try await loadClassGoalViews(
            testSetupID: submission.testSetupID, props: setupProps, on: req.db)

        let ctx = buildSubmissionContext(
            subID: subID,
            submission: submission,
            processed: processed,
            sectionedOutcomes: sectionedOutcomes,
            decorations: SubmissionDecorations(
                badges: badges,
                currentUser: req.currentUserContext,
                overrideGradePercent: overrideGradePercent,
                classGoals: classGoals
            ),
            delta: DeltaBanner(hasDelta: hasDelta, headerText: deltaHeaderText)
        )
        return try await req.view.render("submission", ctx)
    }

    // MARK: - submissionPage helpers

    /// Selects the result row to render on the submission page: the worker
    /// result is preferred (official grade); the browser result is the
    /// fallback used for in-page preview while the worker is still queued.
    private func loadPreferredDisplayResult(
        subID: String, on db: Database
    ) async throws -> APIResult? {
        let allResults = try await APIResult.query(on: db)
            .filter(\.$submissionID == subID)
            .sort(\.$receivedAt, .descending)
            .all()
        let workerResult = allResults.first { ($0.source ?? "worker") == "worker" }
        let browserResult = allResults.first { $0.source == "browser" }
        return workerResult ?? browserResult
    }

    /// Fetches the immediately-prior attempt for per-test delta display and the
    /// Comeback Kid badge.  Returns `(outcomeMap: empty, gradePercent: nil)`
    /// when there is no prior attempt or no decodable prior result.
    private func loadPriorAttemptDelta(
        submission: APISubmission, decoder: JSONDecoder, on db: Database
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
            let data = priorResult.collectionJSON.data(using: .utf8),
            let priorCollection = try? decoder.decode(TestOutcomeCollection.self, from: data)
        else {
            return .empty
        }

        var outcomeMap: [String: TestStatus] = [:]
        for o in priorCollection.outcomes {
            outcomeMap[o.testName] = o.status
        }
        let gradePercent: Int? =
            priorCollection.totalPoints > 0
            ? Int(
                (priorCollection.earnedPoints / Double(priorCollection.totalPoints) * 100).rounded()
            )
            : nil
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
                let stem = (entry.script as NSString).deletingPathExtension
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
            sections: sections, entries: entries)
    }
}

// `SubmitFormBody` and the submission-output formatting helpers live in
// Sources/APIServer/Helpers/SubmissionOutputFormatting.swift.
