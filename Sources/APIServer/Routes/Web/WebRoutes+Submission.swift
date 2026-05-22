// APIServer/Routes/Web/WebRoutes+Submission.swift
//
// Submission-related handlers and helpers for WebRoutes.
// Extracted from WebRoutes.swift — no behaviour changes.

import Core
import Fluent
import Foundation
import Vapor

/// Groups a flat outcome list into per-section buckets for the student
/// submission view.  Sections are emitted in `sections` order; an
/// outcome whose originating entry had no `sectionID` (or a stale one)
/// falls into a trailing bucket with `sectionName == nil`.  When every
/// outcome is ungrouped and there are no sections, the result is one
/// bucket with `sectionName == nil` — template renders it as a single
/// unlabelled table, identical to the pre-sections layout.
///
/// `sectionIDPerOutcome` is a parallel array: `sectionIDPerOutcome[i]`
/// is the section id of the manifest entry that produced `outcomes[i]`
/// (or nil when ungrouped).  Index correlation — not a testName lookup
/// — because two pattern families in different sections can legally
/// share a case label (e.g. both `bmi` and `age` having a "Test 1"
/// case), and a name-keyed dict silently collapsed them onto the
/// last-written section (v0.4.105 fix).
func groupOutcomesBySection(
    _ outcomes: [OutcomeRow],
    sections: [TestSuiteSection],
    sectionIDPerOutcome: [String?]
) -> [SectionedOutcomes] {
    let knownSectionIDs = Set(sections.map(\.id))
    var bucketsByID: [String: [OutcomeRow]] = [:]
    var ungrouped: [OutcomeRow] = []
    for (i, row) in outcomes.enumerated() {
        let sid: String? = (i < sectionIDPerOutcome.count) ? sectionIDPerOutcome[i] : nil
        if let sid, knownSectionIDs.contains(sid) {
            bucketsByID[sid, default: []].append(row)
        } else {
            ungrouped.append(row)
        }
    }
    var result: [SectionedOutcomes] = []
    for section in sections {
        if let rows = bucketsByID[section.id], !rows.isEmpty {
            result.append(SectionedOutcomes(sectionName: section.name, outcomes: rows))
        }
    }
    if !ungrouped.isEmpty {
        // Trailing bucket label: when sections exist, call it "Ungrouped"
        // so students see why this block appears separately.  When no
        // sections exist at all, emit it unlabelled to preserve the
        // legacy single-table look.
        let label: String? = sections.isEmpty ? nil : "Ungrouped"
        result.append(SectionedOutcomes(sectionName: label, outcomes: ungrouped))
    }
    if result.isEmpty {
        // Empty outcome list still needs one bucket so the template's
        // `#for(sec in sectionedOutcomes)` has something to skip over
        // gracefully.  An empty `outcomes` array renders as an empty
        // tbody, just like today.
        result.append(SectionedOutcomes(sectionName: nil, outcomes: []))
    }
    return result
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

        // Attempt number is scoped to this student for this test setup.
        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == user.id)
            .filter(\.$kind == APISubmission.Kind.student)
            .count()

        let submission = APISubmission(
            id: subID,
            testSetupID: setupID,
            zipPath: filePath,
            attemptNumber: priorCount + 1,
            filename: fallbackFilename,
            userID: user.id,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: req.db)
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
        if user.role == "student", let uid = user.id {
            let pathfinderExists =
                try await APIClassAchievement.query(on: req.db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$achievementID == "pathfinder")
                .first() != nil
            if !pathfinderExists {
                let badge = APIClassAchievement(
                    testSetupID: setupID, achievementID: "pathfinder",
                    userID: uid, submissionID: subID)
                try? await badge.save(on: req.db)
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

        let submissionIDs = submissions.compactMap(\.id)
        var preferredResultBySubmissionID: [String: APIResult] = [:]
        if !submissionIDs.isEmpty {
            let results = try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .sort(\.$receivedAt, .descending)
                .all()
            for row in results {
                let key = row.submissionID
                if let existing = preferredResultBySubmissionID[key] {
                    let existingSource = existing.source ?? "worker"
                    let currentSource = row.source ?? "worker"
                    if existingSource == "worker" { continue }
                    if currentSource == "worker" {
                        preferredResultBySubmissionID[key] = row
                    }
                } else {
                    preferredResultBySubmissionID[key] = row
                }
            }
        }

        let rows = submissions.map { submission -> SubmissionHistoryRow in
            let subID = submission.id ?? ""
            let gradeText: String
            if let result = preferredResultBySubmissionID[subID],
                let pct = gradePercentFromCollectionJSON(result.collectionJSON)
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

        // Students may only view their own submissions.
        if !user.isInstructor {
            guard submission.userID == user.id else {
                throw Abort(.forbidden)
            }
        }

        // Fetch the assignment for deadline-based tier visibility.
        let submissionAssignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == submission.testSetupID)
            .first()
        let allowedTiers = visibleTiers(for: user, assignment: submissionAssignment)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let displayResult = try await loadPreferredDisplayResult(subID: subID, on: req.db)
        let priorAttempt = try await loadPriorAttemptDelta(
            submission: submission, decoder: decoder, on: req.db)
        let manifestDisplay = try await loadManifestDisplayData(
            testSetupID: submission.testSetupID, on: req.db)

        var processed = ProcessedCollection.empty
        if let result = displayResult {
            processed = processDisplayResult(
                result: result,
                viewer: SubmissionViewer(user: user, allowedTiers: allowedTiers),
                submission: submission,
                priorAttempt: priorAttempt,
                manifestDisplay: manifestDisplay,
                decoder: decoder
            )
        }

        // Append class-wide achievement badges held by this specific submission.
        let classAchievements = try await APIClassAchievement.query(on: req.db)
            .filter(\.$submissionID == subID)
            .all()
        let badges =
            processed.badges
            + classAchievements.compactMap { AchievementBadge.forClassAchievement($0.achievementID) }

        let sectionedOutcomes = buildSectionedOutcomes(
            outcomes: processed.outcomes,
            manifestEntries: manifestDisplay.entries,
            manifestSections: manifestDisplay.sections,
            allowedTiers: allowedTiers
        )

        let currentAttempt = submission.attemptNumber ?? 1
        let hasDelta = !priorAttempt.outcomeMap.isEmpty
        let deltaHeaderText = buildDeltaHeaderText(
            outcomes: processed.outcomes,
            hasDelta: hasDelta,
            currentAttempt: currentAttempt
        )

        let ctx = buildSubmissionContext(
            subID: subID,
            submission: submission,
            processed: processed,
            sectionedOutcomes: sectionedOutcomes,
            decorations: SubmissionDecorations(badges: badges, currentUser: req.currentUserContext),
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
                (Double(priorCollection.earnedPoints) / Double(priorCollection.totalPoints) * 100).rounded()
            )
            : nil
        return PriorAttemptDelta(outcomeMap: outcomeMap, gradePercent: gradePercent)
    }

    /// Reads the manifest from `APITestSetup` and extracts:
    /// - a script/stem→displayName map so the page shows friendly names for
    ///   worker results that already use the display name directly, older
    ///   worker results where testName is the filename stem, and browser
    ///   results where testName is the full script filename;
    /// - the manifest's section list and the full `testSuites` list, so the
    ///   page can build a parallel `sectionIDPerOutcome` array.  We can't do
    ///   a name-keyed lookup because two families in different sections may
    ///   legally share case labels (v0.4.105 bug).
    private func loadManifestDisplayData(
        testSetupID: String, on db: Database
    ) async throws -> ManifestDisplayData {
        var displayNameMap: [String: String] = [:]
        var hintByFilename: [String: String] = [:]
        var sections: [TestSuiteSection] = []
        var entries: [TestSuiteEntry] = []
        if let setup = try? await APITestSetup.find(testSetupID, on: db),
            let manifestData = setup.manifest.data(using: .utf8),
            let props = decodeManifest(from: manifestData)
        {
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

    /// Decodes the chosen result's `TestOutcomeCollection`, filters by tier,
    /// computes totals and badges, and renders each visible outcome into an
    /// `OutcomeRow` for the template.  Hidden-tier summaries (release before
    /// deadline, secret) are computed for non-instructors only — instructors
    /// see every tier directly.
    private func processDisplayResult(
        result: APIResult,
        viewer: SubmissionViewer,
        submission: APISubmission,
        priorAttempt: PriorAttemptDelta,
        manifestDisplay: ManifestDisplayData,
        decoder: JSONDecoder
    ) -> ProcessedCollection {
        var processed = ProcessedCollection.empty
        processed.resultSource = result.source ?? "worker"
        guard let data = result.collectionJSON.data(using: .utf8),
            let collection = try? decoder.decode(TestOutcomeCollection.self, from: data)
        else {
            return processed
        }

        // Compute per-tier summaries from the full (unfiltered) collection.
        if !viewer.user.isInstructor {
            let releaseOutcomes = collection.outcomes.filter { $0.tier == .release }
            let secretOutcomes = collection.outcomes.filter { $0.tier == .secret }
            let releaseVisible = viewer.allowedTiers.contains("release")
            if !releaseVisible, !releaseOutcomes.isEmpty {
                processed.releaseSummary = TierSummary(outcomes: releaseOutcomes, isRelease: true)
            }
            if !secretOutcomes.isEmpty {
                processed.secretSummary = TierSummary(outcomes: secretOutcomes, isRelease: false)
            }
        }

        let visible = collection.filtering(tiers: viewer.allowedTiers)
        processed.buildFailed = collection.buildStatus == .failed
        processed.compilerOutput = collection.compilerOutput
        processed.warnings = collection.warnings
        processed.passCount = visible.passCount
        processed.totalTests = visible.totalTests
        processed.executionTimeMs = collection.executionTimeMs
        processed.totalPoints = visible.totalPoints
        processed.earnedPoints = visible.earnedPoints
        processed.gradePercent =
            processed.totalPoints > 0
            ? Int((Double(processed.earnedPoints) / Double(processed.totalPoints) * 100).rounded())
            : 0
        processed.badges = AchievementBadge.forSubmission(
            BadgeContext(
                attemptNumber: submission.attemptNumber ?? 1,
                gradePercent: processed.gradePercent,
                executionTimeMs: collection.executionTimeMs,
                priorGradePercent: priorAttempt.gradePercent
            ))
        let weighted = processed.totalPoints != visible.totalTests
        processed.outcomes = visible.outcomes.map { outcome in
            renderOutcomeRow(
                outcome: outcome,
                weighted: weighted,
                priorOutcomeMap: priorAttempt.outcomeMap,
                displayNameMap: manifestDisplay.displayNameMap,
                hintByFilename: manifestDisplay.hintByFilename
            )
        }
        return processed
    }

    /// Renders a single `TestOutcome` into the template-facing `OutcomeRow`.
    /// Pulled out of `processDisplayResult` so the per-row formatting stays
    /// inspectable in isolation.
    private func renderOutcomeRow(
        outcome: TestOutcome,
        weighted: Bool,
        priorOutcomeMap: [String: TestStatus],
        displayNameMap: [String: String],
        hintByFilename: [String: String]
    ) -> OutcomeRow {
        let skip = parseSkip(shortResult: outcome.shortResult)
        let shortOutput = formattedShortResult(from: outcome.shortResult, status: outcome.status)
        let longOutput =
            outcome.status == .pass
            ? formattedPassingDetailedOutput(primary: outcome.longResult)
            : formattedDetailedOutput(
                primary: outcome.longResult,
                fallback: outcome.shortResult,
                status: outcome.status
            )
        let (markLabel, markClass): (String, String) = {
            if skip.isSkipped { return ("—", "skipped") }
            switch outcome.status {
            case .pass: return ("Pass", "pass")
            case .fail: return ("Fail", "fail")
            case .error: return ("Error", "error")
            case .timeout: return ("Timeout", "timeout")
            }
        }()
        let (deltaImproved, deltaRegressed): (Bool, Bool) = {
            guard let prior = priorOutcomeMap[outcome.testName] else { return (false, false) }
            let wasPass = (prior == .pass)
            let isPass = (outcome.status == .pass)
            return (!wasPass && isPass, wasPass && !isPass)
        }()
        let pointsLabel: String? = weighted && outcome.points > 1 ? "\(outcome.points) pts" : nil
        // Surface the instructor hint only on a genuine failure (not pass, not
        // a skipped/blocked test — there the blocker message is the guidance).
        let hint: String? =
            (!skip.isSkipped && outcome.status != .pass)
            ? hintByFilename[outcome.testName] : nil
        return OutcomeRow(
            testName: displayNameMap[outcome.testName] ?? outcome.testName,
            tier: outcome.tier.rawValue,
            status: outcome.status.rawValue,
            shortResult: shortOutput,
            longResult: longOutput,
            markLabel: markLabel,
            markClass: markClass,
            isSkipped: skip.isSkipped,
            blockerName: skip.blockerName,
            deltaImproved: deltaImproved,
            deltaRegressed: deltaRegressed,
            pointsLabel: pointsLabel,
            hint: hint
        )
    }

    /// Worker emits exactly one outcome per `manifest.testSuites` entry, in
    /// the same order.  The student-visible outcomes are filtered by tier, so
    /// we filter `manifestEntries` by the same tier predicate to keep the
    /// parallel-index correlation aligned (`outcomes[i]` ↔ `visibleEntries[i]`).
    /// We then defensively pad/truncate the section-id array in case browser-
    /// mode submissions emit a slightly different shape or a manifest churn
    /// happens mid-flight — drift falls into Ungrouped rather than
    /// misattributing outcomes.
    private func buildSectionedOutcomes(
        outcomes: [OutcomeRow],
        manifestEntries: [TestSuiteEntry],
        manifestSections: [TestSuiteSection],
        allowedTiers: Set<String>
    ) -> [SectionedOutcomes] {
        let visibleEntries = manifestEntries.filter { allowedTiers.contains($0.tier.rawValue) }
        var sectionIDPerOutcome: [String?] = visibleEntries.map { $0.sectionID }
        if sectionIDPerOutcome.count < outcomes.count {
            sectionIDPerOutcome.append(
                contentsOf:
                    Array(repeating: String?.none, count: outcomes.count - sectionIDPerOutcome.count))
        } else if sectionIDPerOutcome.count > outcomes.count {
            sectionIDPerOutcome = Array(sectionIDPerOutcome.prefix(outcomes.count))
        }
        return groupOutcomesBySection(
            outcomes,
            sections: manifestSections,
            sectionIDPerOutcome: sectionIDPerOutcome
        )
    }

    /// Composes the human-readable banner text shown above the outcomes table
    /// when this attempt is being compared with the previous one.  Returns nil
    /// when there's no prior attempt to compare against.
    private func buildDeltaHeaderText(
        outcomes: [OutcomeRow], hasDelta: Bool, currentAttempt: Int
    ) -> String? {
        guard hasDelta else { return nil }
        let improved = outcomes.filter { $0.deltaImproved }.count
        let regressed = outcomes.filter { $0.deltaRegressed }.count
        var parts: [String] = []
        if improved > 0 { parts.append("↑ fixed \(improved) test\(improved  == 1 ? "" : "s")") }
        if regressed > 0 { parts.append("↓ broke \(regressed) test\(regressed == 1 ? "" : "s")") }
        if parts.isEmpty { return "No change since attempt \(currentAttempt - 1)" }
        return parts.joined(separator: " · ") + " since attempt \(currentAttempt - 1)"
    }

    /// Builds the final Leaf-facing `SubmissionContext` from the processed
    /// pieces.  Pulled out so `submissionPage` itself stays a thin orchestrator.
    private func buildSubmissionContext(
        subID: String,
        submission: APISubmission,
        processed: ProcessedCollection,
        sectionedOutcomes: [SectionedOutcomes],
        decorations: SubmissionDecorations,
        delta: DeltaBanner
    ) -> SubmissionContext {
        let badges = decorations.badges
        let currentUser = decorations.currentUser
        let isPending = submission.status == "pending" || submission.status == "assigned"
        let isBrowserComplete = false  // browser submissions now go straight to "complete"
        let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
        let nameExt = (submission.filename ?? "").lowercased()
        let openInNotebookURL: String? =
            (pathExt == "ipynb" || nameExt.hasSuffix(".ipynb"))
            ? "/testsetups/\(submission.testSetupID)/notebook?submissionID=\(subID)"
            : nil
        return SubmissionContext(
            submissionID: subID,
            testSetupID: submission.testSetupID,
            status: submission.status,
            attemptNumber: submission.attemptNumber ?? 1,
            submissionFilename: submission.filename,
            openInNotebookURL: openInNotebookURL,
            isPending: isPending,
            isBrowserComplete: isBrowserComplete,
            resultSource: processed.resultSource,
            buildFailed: processed.buildFailed,
            compilerOutput: processed.compilerOutput,
            hasWarnings: !processed.warnings.isEmpty,
            warnings: processed.warnings,
            outcomes: processed.outcomes,
            sectionedOutcomes: sectionedOutcomes,
            passCount: processed.passCount,
            totalTests: processed.totalTests,
            gradePercent: processed.gradePercent,
            executionTimeMs: processed.executionTimeMs,
            isWeighted: processed.totalPoints != processed.totalTests,
            totalPoints: processed.totalPoints,
            earnedPoints: processed.earnedPoints,
            hasDelta: delta.hasDelta,
            deltaHeaderText: delta.headerText,
            releaseSummary: processed.releaseSummary,
            secretSummary: processed.secretSummary,
            badges: badges,
            currentUser: currentUser
        )
    }
}

// MARK: - submissionPage support types

/// All values derived from decoding & filtering the chosen
/// `TestOutcomeCollection`.  Bundled into a struct so the per-helper signatures
/// stay readable.
private struct ProcessedCollection {
    var resultSource: String  // "browser" | "worker" | ""
    var buildFailed: Bool
    var compilerOutput: String?
    var warnings: [String]
    var outcomes: [OutcomeRow]
    var passCount: Int
    var totalTests: Int
    var totalPoints: Int
    var earnedPoints: Int
    var executionTimeMs: Int
    var gradePercent: Int
    var badges: [AchievementBadge]
    var releaseSummary: TierSummary?
    var secretSummary: TierSummary?

    static let empty = ProcessedCollection(
        resultSource: "",
        buildFailed: false,
        compilerOutput: nil,
        warnings: [],
        outcomes: [],
        passCount: 0,
        totalTests: 0,
        totalPoints: 0,
        earnedPoints: 0,
        executionTimeMs: 0,
        gradePercent: 0,
        badges: [],
        releaseSummary: nil,
        secretSummary: nil
    )
}

/// Delta information harvested from the immediately-prior attempt.
private struct PriorAttemptDelta {
    let outcomeMap: [String: TestStatus]
    let gradePercent: Int?

    static let empty = PriorAttemptDelta(outcomeMap: [:], gradePercent: nil)
}

/// Manifest-derived data used for friendly test names and section bucketing.
/// Maps each generated/raw test filename — and its extensionless stem, so it
/// matches both the worker (`testName == stem`) and browser (`testName ==
/// filename`) outcome shapes — to its instructor hint: per-case `resolvedHint`
/// for pattern families, `hint` for notebook checks, and the suite-entry `hint`
/// for hand-written raw scripts.  The results view surfaces this as a "💡 Hint"
/// callout on failing tests (v0.4.229), replacing the hint text that
/// pattern-family scripts used to bake into their own output.
func buildHintByFilename(_ props: TestProperties) -> [String: String] {
    var map: [String: String] = [:]
    func record(_ filename: String, _ hint: String?) {
        guard let h = hint,
            !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let stem = (filename as NSString).deletingPathExtension
        map[filename] = h
        map[stem.isEmpty ? filename : stem] = h
    }
    // Raw scripts carry their hint on the suite entry; generated entries take
    // it from the family-case / check spec instead.
    for entry in props.testSuites where !entry.isGenerated {
        record(entry.script, entry.hint)
    }
    for f in props.patternFamilies {
        for c in f.cases where c.enabled {
            record(
                generatedScriptFilename(
                    familyID: f.id, caseKey: c.key,
                    tier: c.resolvedTier(defaults: f.defaults)),
                c.resolvedHint(defaults: f.defaults))
        }
    }
    for chk in props.notebookChecks {
        record(generatedCheckFilename(checkID: chk.id, tier: chk.tier), chk.hint)
    }
    return map
}

private struct ManifestDisplayData {
    let displayNameMap: [String: String]
    let hintByFilename: [String: String]
    let sections: [TestSuiteSection]
    let entries: [TestSuiteEntry]
}

/// Viewer-side inputs that gate which tiers and summaries are visible.
private struct SubmissionViewer {
    let user: APIUser
    let allowedTiers: Set<String>
}

/// Banner text shown above the outcomes table comparing this attempt against
/// the previous one.  `headerText` is nil when `hasDelta` is false.
private struct DeltaBanner {
    let hasDelta: Bool
    let headerText: String?
}

/// Per-page decoration data attached to `SubmissionContext` — class-wide
/// achievement badges and the current user's display context.
private struct SubmissionDecorations {
    let badges: [AchievementBadge]
    let currentUser: CurrentUserContext?
}

// `SubmitFormBody` and the submission-output formatting helpers live in
// Sources/APIServer/Helpers/SubmissionOutputFormatting.swift.
