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
    let props = setup?.decodedManifest()
    let disabled = Set(props?.disabledBuiltInAwardIDs ?? [])
    return AchievementBadge.forSubmission(
        badgeContext,
        achievements: BuiltInAchievements.manifestPerSubmission(props: props),
        disabled: disabled)
        + classAchievements.compactMap {
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
            throw Abort(.notFound)
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
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        // Mirror the notebook page's closed-assignment gate: a student who has
        // never opened this (now-closed) upload-mode assignment is sent to
        // their dashboard rather than shown an upload form they cannot submit.
        if let userID = user.id, let assignment {
            let isClosed = !(try await isAssignmentEffectivelyOpen(assignment, for: user, req: req))
            if let redirect = try await closedAssignmentGate(
                req: req, user: user, userID: userID, assignment: assignment, isClosed: isClosed)
            {
                return redirect
            }
        }
        let requiredFiles = manifest?.requiredFiles ?? []
        // The deadline actually in force for this student: a personal extension
        // outranks the class due date, which is what the chip must show.
        let extensionDueAt: Date? =
            if let assignment {
                try await studentExtensionDueAt(for: assignment, user: user, on: req.db)
            } else { nil }
        let deadline = laterDeadline(
            baseline: assignment?.dueAt, extensionDueAt: extensionDueAt)
        let priorAttempts: Int =
            if let userID = user.id {
                try await APISubmission.query(on: req.db)
                    .filter(\.$testSetupID == setupID)
                    .filter(\.$userID == userID)
                    .count()
            } else { 0 }
        return try await req.view.render(
            "submit",
            SubmitContext(
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                acceptAttribute: submissionAcceptAttribute(manifest: manifest),
                acceptHintText: submissionAcceptHintText(manifest: manifest),
                errorText: req.query[String.self, at: "error"] == "filetype"
                    ? submissionRejectionMessage(manifest: manifest) : nil,
                requiredFilesText: requiredFiles.isEmpty
                    ? nil : requiredFiles.joined(separator: ", "),
                attemptNumber: priorAttempts + 1,
                deadlineText: deadline.map { waterlooDateTimeFormatter().string(from: $0) },
                deadlineISO: deadline.map(iso8601String),
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
        let manifest = decodeManifest(from: manifestData)
        if manifest?.effectiveGradingMode == .browser {
            return req.redirect(to: "/testsetups/\(setupID)/notebook")
        }

        _ = try await requireOpenStudentAssignment(for: setupID, user: user, on: req)

        let body = try req.content.decode(SubmitFormBody.self)

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
        // Offloaded to the NIO thread pool, matching the API submission path: a
        // synchronous write pins a cooperative-pool thread while the handler
        // still holds the whole body in memory, and a deadline burst is exactly
        // when this route is hot.
        try await req.fileio.writeFile(.init(data: fileData), at: filePath)
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
        // The shared helper carries the v0.4.127 role gate (an admin/TA/
        // instructor testing the assignment must not lock in the immutable
        // badge) and is the same code path the notebook submission routes use.
        if let uid = user.id {
            try await awardFirstToSubmitRecords(
                setup: setup, userID: uid, submissionID: subID, on: req.db)
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
        let releaseDeadline = try await releaseVisibilityDeadline(
            for: submissionAssignment, user: user, on: req.db)
        let releaseOutput = releaseOutputVisible(isStaff: isStaff, effectiveDueAt: releaseDeadline)

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

        try await applyClassGoalBonus(
            to: &processed, setupProps: setupProps,
            testSetupID: submission.testSetupID, on: req.db)

        let badges = try await submissionBadges(
            req: req, subID: subID, displayCollection: displayCollection,
            setupProps: setupProps, setup: setup, processed: processed)

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
                classGoals: classGoals,
                secretReveal: SecretRevealBanner(
                    available: reveal.enabled && !reveal.spent && !isStaff
                        && hasSecretTierTests(setupProps),
                    active: reveal.revealed)
            ),
            delta: DeltaBanner(hasDelta: hasDelta, headerText: deltaHeaderText)
        )
        return try await req.view.render("submission", ctx)
    }

    // MARK: - submissionPage helpers

    /// Class-goal bonus: true extra credit on the autograded grade, so a
    /// student already at full marks reads above 100% (no-op unless the
    /// assignment has a points-rewarded class goal).
    private func applyClassGoalBonus(
        to processed: inout ProcessedCollection,
        setupProps: TestProperties?,
        testSetupID: String,
        on db: Database
    ) async throws {
        guard processed.totalPoints > 0 else { return }
        let bonus = try await classGoalBonusPoints(
            testSetupID: testSetupID, props: setupProps, on: db)
        guard bonus > 0 else { return }
        let bonused = earnedWithClassGoalBonus(
            earned: processed.rawEarnedPoints,
            total: Double(processed.totalPoints),
            bonus: bonus)
        processed.gradePercent = Int(
            (bonused / Double(processed.totalPoints) * 100).rounded())
        processed.earnedPoints = formatPoints(bonused)
    }

    /// Assembles the badge strip for one submission: class-wide achievement
    /// badges held by this specific submission, built-in badges, and
    /// authorable individual badges (threshold / test) earned per-student from
    /// this submission's result — the latter evaluated over all tiers so a
    /// secret-test badge works without revealing the test.
    private func submissionBadges(
        req: Request,
        subID: String,
        displayCollection: TestOutcomeCollection?,
        setupProps: TestProperties?,
        setup: APITestSetup?,
        processed: ProcessedCollection
    ) async throws -> [AchievementBadge] {
        let classAchievements = try await APIClassAchievement.query(on: req.db)
            .filter(\.$submissionID == subID)
            .all()
        let individualBadges = earnedIndividualBadgesForDisplay(
            collection: displayCollection, props: setupProps,
            gradePercent: processed.gradePercent)
        return builtInBadgesForSubmission(
            badgeContext: processed.badgeContext,
            classAchievements: classAchievements,
            setup: setup)
            + individualBadges
    }

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

    /// The preferred display result plus its collection, fetched from the
    /// result_collections side table and decoded ONCE (#1173) — the presenter
    /// and the individual-badge evaluation share the decoded value.
    private func loadDisplayResultAndCollection(
        subID: String, decoder: JSONDecoder, on db: Database
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
            sections: sections, entries: entries,
            testNameAliases: props?.testNameAliases() ?? [:])
    }
}

// `SubmitFormBody` and the submission-output formatting helpers live in
// Sources/APIServer/Helpers/SubmissionOutputFormatting.swift.
