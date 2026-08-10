// APIServer/Routes/Web/SubmissionResultPresenter.swift
//
// Result-presentation pipeline for the student submission page: decoding the
// chosen `TestOutcomeCollection` into template-facing rows, section bucketing,
// delta banners, hint lookup, and the supporting display structs.
// Extracted from WebRoutes+Submission.swift — no behaviour changes.

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
///
/// `secretOutcomes` / `sectionIDPerSecretOutcome` carry the secret-tier
/// outcomes (never itemized for students) plus their per-outcome section
/// ids, correlated the same way.  They are aggregated into a per-section
/// `secretSummary` so a student can see *where* hidden tests are failing
/// without revealing which.  A section that contains only secret tests is
/// still emitted (with empty `outcomes` and a non-nil `secretSummary`) so
/// the student gets a signal for that question; secret outcomes with no
/// (or a stale) section fall into the trailing/ungrouped bucket alongside
/// any ungrouped visible rows.
func groupOutcomesBySection(
    _ outcomes: [OutcomeRow],
    sections: [TestSuiteSection],
    sectionIDPerOutcome: [String?],
    secretOutcomes: [TestOutcome] = [],
    sectionIDPerSecretOutcome: [String?] = []
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
    // Secret outcomes are counted, never itemized: bucket them by section the
    // same way, then fold each bucket into an aggregate `TierSummary`.
    var secretByID: [String: [TestOutcome]] = [:]
    var secretUngrouped: [TestOutcome] = []
    for (i, outcome) in secretOutcomes.enumerated() {
        let sid: String? = (i < sectionIDPerSecretOutcome.count) ? sectionIDPerSecretOutcome[i] : nil
        if let sid, knownSectionIDs.contains(sid) {
            secretByID[sid, default: []].append(outcome)
        } else {
            secretUngrouped.append(outcome)
        }
    }
    func summary(_ list: [TestOutcome]) -> TierSummary? {
        list.isEmpty ? nil : TierSummary(outcomes: list, isRelease: false)
    }
    var result: [SectionedOutcomes] = []
    for section in sections {
        let rows = bucketsByID[section.id] ?? []
        let secret = secretByID[section.id] ?? []
        if rows.isEmpty && secret.isEmpty { continue }
        result.append(
            SectionedOutcomes(
                sectionName: section.name, outcomes: rows, secretSummary: summary(secret)))
    }
    if !ungrouped.isEmpty || !secretUngrouped.isEmpty {
        // Trailing bucket label: when sections exist, call it "Ungrouped"
        // so students see why this block appears separately.  When no
        // sections exist at all, emit it unlabelled to preserve the
        // legacy single-table look.
        let label: String? = sections.isEmpty ? nil : "Ungrouped"
        result.append(
            SectionedOutcomes(
                sectionName: label, outcomes: ungrouped, secretSummary: summary(secretUngrouped)))
    }
    if result.isEmpty {
        // Empty outcome list still needs one bucket so the template's
        // `#for(sec in sectionedOutcomes)` has something to skip over
        // gracefully.  An empty `outcomes` array renders as an empty
        // tbody, just like today.
        result.append(SectionedOutcomes(sectionName: nil, outcomes: [], secretSummary: nil))
    }
    return result
}

extension WebRoutes {

    // MARK: - Result presentation

    // Internal (was private): called from `submissionPage` in WebRoutes+Submission.swift.
    /// Renders the chosen result's already-decoded `TestOutcomeCollection`
    /// (the caller fetches the blob from the result_collections side table,
    /// #1173): computes the all-tier grade (so the number matches the
    /// dashboard and is stable across the deadline), and renders each
    /// *itemized* outcome into an `OutcomeRow`. Students see public + release
    /// rows; release output is redacted until the deadline. Secret appears as
    /// rows only for staff or a student with a spent secret-reveal token —
    /// otherwise it is surfaced as an aggregate pass/fail `TierSummary`.
    func processDisplayResult(
        result: APIResult,
        collection maybeCollection: TestOutcomeCollection?,
        viewer: SubmissionViewer,
        submission: APISubmission,
        priorAttempt: PriorAttemptDelta,
        manifestDisplay: ManifestDisplayData
    ) -> ProcessedCollection {
        var processed = ProcessedCollection.empty
        processed.resultSource = result.source ?? "worker"
        guard let collection = maybeCollection else {
            return processed
        }

        // Secret tests count toward the grade but are not itemized for
        // students (unless they spent their secret-reveal token); they are
        // bucketed into per-section aggregate pass/fail summaries by
        // `buildSectionedOutcomes`.  Kept in collection order so the section
        // correlation lines up with the secret manifest entries.  When
        // revealed, secret outcomes flow through the itemized rows below
        // instead, and this stays empty — so the aggregate never doubles up.
        if !viewer.isStaff && !viewer.secretRevealed {
            processed.secretOutcomes = collection.outcomes.filter { $0.tier == .secret }
        }

        // Grade spans every tier (matches `gradePercentFromCollectionJSON` on
        // the dashboard); only the itemized rows are tier-filtered.
        processed.buildFailed = collection.buildStatus == .failed
        processed.compilerOutput = collection.compilerOutput
        processed.warnings = collection.warnings
        processed.passCount = collection.passCount
        processed.totalTests = collection.totalTests
        processed.executionTimeMs = collection.executionTimeMs
        processed.totalPoints = collection.totalPoints
        processed.rawEarnedPoints = collection.earnedPoints
        processed.earnedPoints = formatPoints(collection.earnedPoints)
        processed.gradePercent =
            collection.totalPoints > 0
            ? Int((collection.earnedPoints / Double(collection.totalPoints) * 100).rounded())
            : 0
        processed.badgeContext = BadgeContext(
            attemptNumber: submission.attemptNumber ?? 1,
            gradePercent: processed.gradePercent,
            executionTimeMs: collection.executionTimeMs,
            priorGradePercent: priorAttempt.gradePercent,
            outcomes: collection.outcomes,
            testNameAliases: manifestDisplay.testNameAliases
        )
        let weighted = collection.totalPoints != collection.totalTests
        let itemized = collection.filtering(tiers: viewer.itemizedTiers)
        processed.outcomes = itemized.outcomes.map { outcome in
            // Release output stays hidden until the deadline; the row (name,
            // mark, hint) still renders so the student knows which test failed.
            let redactOutput = outcome.tier == .release && !viewer.releaseOutputVisible
            return renderOutcomeRow(
                outcome: outcome,
                weighted: weighted,
                redactOutput: redactOutput,
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
        redactOutput: Bool,
        priorOutcomeMap: [String: TestStatus],
        displayNameMap: [String: String],
        hintByFilename: [String: String]
    ) -> OutcomeRow {
        let skip = parseSkip(shortResult: outcome.shortResult)
        let shortOutput: String
        let longOutput: String?
        if redactOutput {
            // Release before the deadline: the name, mark, and hint still show
            // so the student knows which hidden test is failing, but the result
            // message and output panel (which can leak expected/actual values)
            // are withheld until the deadline.
            longOutput = nil
            shortOutput =
                (outcome.status == .pass || skip.isSkipped)
                ? "" : "Detailed feedback is available after the deadline."
        } else {
            shortOutput = formattedShortResult(from: outcome.shortResult, status: outcome.status)
            longOutput =
                outcome.status == .pass
                ? formattedPassingDetailedOutput(primary: outcome.longResult)
                : formattedDetailedOutput(
                    primary: outcome.longResult,
                    fallback: outcome.shortResult,
                    status: outcome.status
                )
        }
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
        // Partial credit (#548): when a test earned a fraction of its points
        // (0 < score < 1, typically a script that emitted an explicit footer
        // `score`), surface it as "1.5 / 2 pts" so the student sees the credit
        // even though the status badge reads Fail. Full credit / no credit keep
        // the plain weight label, shown only on weighted assignments.
        let pointsLabel: String? = {
            if outcome.score > 0, outcome.score < 1 {
                let earned = formatPoints(outcome.score * Double(outcome.points))
                let unit = outcome.points == 1 ? "pt" : "pts"
                return "\(earned) / \(outcome.points) \(unit)"
            }
            return weighted && outcome.points > 1 ? "\(outcome.points) pts" : nil
        }()
        // Surface the instructor hint only on a genuine failure (not pass, not
        // a skipped/blocked test — there the blocker message is the guidance).
        // Hints are shown for failing release rows too, even before the deadline.
        let hint: String? =
            (!skip.isSkipped && outcome.status != .pass)
            ? hintByFilename[outcome.testName] : nil
        // Don't reveal a (possibly hidden-tier) prerequisite name when output
        // is redacted.
        let blockerName = redactOutput ? nil : skip.blockerName
        return OutcomeRow(
            testName: displayNameMap[outcome.testName] ?? outcome.testName,
            tier: outcome.tier.rawValue,
            status: outcome.status.rawValue,
            shortResult: shortOutput,
            longResult: longOutput,
            markLabel: markLabel,
            markClass: markClass,
            isSkipped: skip.isSkipped,
            blockerName: blockerName,
            deltaImproved: deltaImproved,
            deltaRegressed: deltaRegressed,
            pointsLabel: pointsLabel,
            hint: hint
        )
    }

    // Internal (was private): called from `submissionPage` in WebRoutes+Submission.swift.
    /// Worker emits exactly one outcome per `manifest.testSuites` entry, in
    /// the same order.  The student-visible outcomes are filtered by tier, so
    /// we filter `manifestEntries` by the same tier predicate to keep the
    /// parallel-index correlation aligned (`outcomes[i]` ↔ `visibleEntries[i]`).
    /// We then defensively pad/truncate the section-id array in case browser-
    /// mode submissions emit a slightly different shape or a manifest churn
    /// happens mid-flight — drift falls into Ungrouped rather than
    /// misattributing outcomes.
    func buildSectionedOutcomes(
        outcomes: [OutcomeRow],
        secretOutcomes: [TestOutcome],
        manifestEntries: [TestSuiteEntry],
        manifestSections: [TestSuiteSection],
        allowedTiers: Set<String>
    ) -> [SectionedOutcomes] {
        let visibleEntries = manifestEntries.filter { allowedTiers.contains($0.tier.rawValue) }
        let sectionIDPerOutcome = alignSectionIDs(
            visibleEntries.map { $0.sectionID }, toCount: outcomes.count)
        // Secret outcomes never appear in `allowedTiers` for students, so they
        // correlate against the secret-tier manifest entries on their own.
        let secretEntries = manifestEntries.filter { $0.tier == .secret }
        let sectionIDPerSecret = alignSectionIDs(
            secretEntries.map { $0.sectionID }, toCount: secretOutcomes.count)
        return groupOutcomesBySection(
            outcomes,
            sections: manifestSections,
            sectionIDPerOutcome: sectionIDPerOutcome,
            secretOutcomes: secretOutcomes,
            sectionIDPerSecretOutcome: sectionIDPerSecret
        )
    }

    /// Pads with nil / truncates a section-id array so it matches the outcome
    /// count exactly.  Browser-mode submissions or a manifest churn mid-flight
    /// can yield a slightly different shape; misaligned entries fall into
    /// Ungrouped rather than misattributing an outcome to the wrong section.
    private func alignSectionIDs(_ ids: [String?], toCount count: Int) -> [String?] {
        if ids.count < count {
            return ids + Array(repeating: String?.none, count: count - ids.count)
        } else if ids.count > count {
            return Array(ids.prefix(count))
        }
        return ids
    }

    // Internal (was private): called from `submissionPage` in WebRoutes+Submission.swift.
    /// Composes the human-readable banner text shown above the outcomes table
    /// when this attempt is being compared with the previous one.  Returns nil
    /// when there's no prior attempt to compare against.
    func buildDeltaHeaderText(
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

    // Internal (was private): called from `submissionPage` in WebRoutes+Submission.swift.
    /// Builds the final Leaf-facing `SubmissionContext` from the processed
    /// pieces.  Pulled out so `submissionPage` itself stays a thin orchestrator.
    func buildSubmissionContext(
        subID: String,
        submission: APISubmission,
        processed: ProcessedCollection,
        sectionedOutcomes: [SectionedOutcomes],
        decorations: SubmissionDecorations,
        delta: DeltaBanner
    ) -> SubmissionContext {
        let secretReveal = decorations.secretReveal
        let overrideGradePercent = decorations.overrideGradePercent
        let badges = decorations.badges
        let currentUser = decorations.currentUser
        let isPending = submission.statusValue == .pending || submission.statusValue == .assigned
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
            gradeIsOverridden: overrideGradePercent != nil,
            overrideGradeText: overrideGradePercent.map { "\($0)%" },
            executionTimeMs: processed.executionTimeMs,
            isWeighted: processed.totalPoints != processed.totalTests,
            totalPoints: processed.totalPoints,
            earnedPoints: processed.earnedPoints,
            hasDelta: delta.hasDelta,
            deltaHeaderText: delta.headerText,
            badges: badges,
            currentUser: currentUser,
            classGoals: decorations.classGoals,
            hasClassGoals: !decorations.classGoals.isEmpty,
            secretRevealAvailable: secretReveal.available,
            secretRevealActive: secretReveal.active
        )
    }
}

/// Loads an assignment's class-goal achievements joined with their latest
/// `APIAchievementResult` snapshot, for the student-facing "Achievements"
/// section.  Returns `[]` when the manifest carries no class goals.  Takes the
/// caller's already-decoded manifest (#1128) instead of re-fetching the setup.
func loadClassGoalViews(
    testSetupID: String, props: TestProperties?, on db: Database
) async throws -> [ClassGoalView] {
    guard let props else { return [] }
    let goals = props.achievements.filter { $0.isClassGoal }
    guard !goals.isEmpty else { return [] }

    let rows = try await APIAchievementResult.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .all()
    var rowByAchievement: [String: APIAchievementResult] = [:]
    for row in rows { rowByAchievement[row.achievementID] = row }

    return goals.map { goal in
        let row = rowByAchievement[goal.id]
        let progress = row?.progress ?? 0
        let rewardLabel: String
        if goal.reward.type == .points, let points = goal.reward.points {
            rewardLabel = "+\(points) \(points == 1 ? "pt" : "pts")"
        } else {
            rewardLabel = goal.reward.label
        }
        return ClassGoalView(
            name: goal.name,
            detail: goal.detail,
            rewardLabel: rewardLabel,
            progressPercent: Int((progress * 100).rounded()),
            studentsMeeting: row?.studentsMeeting ?? 0,
            denominator: row?.denominator ?? 0,
            met: progress >= 1,
            locked: row?.locked ?? false)
    }
}

// MARK: - submissionPage support types

// Internal (was private): built here, consumed by `submissionPage` in
// WebRoutes+Submission.swift.
/// All values derived from decoding & filtering the chosen
/// `TestOutcomeCollection`.  Bundled into a struct so the per-helper signatures
/// stay readable.
struct ProcessedCollection {
    var resultSource: String  // "browser" | "worker" | ""
    var buildFailed: Bool
    var compilerOutput: String?
    var warnings: [String]
    var outcomes: [OutcomeRow]
    var passCount: Int
    var totalTests: Int
    var totalPoints: Int
    var earnedPoints: String
    /// Raw earned points before display formatting and before any class-goal
    /// bonus — used to recompute the grade when a bonus applies.
    var rawEarnedPoints: Double
    var executionTimeMs: Int
    var gradePercent: Int
    /// Inputs for the per-submission badges; the badges themselves are resolved
    /// at the call site (manifest-sourced when seeded, else the registry).
    var badgeContext: BadgeContext
    /// Secret-tier outcomes (students only) in collection order; aggregated
    /// into per-section summaries by `buildSectionedOutcomes`.  Empty for
    /// instructors, who see secret tests itemized as ordinary rows.
    var secretOutcomes: [TestOutcome]

    static let empty = ProcessedCollection(
        resultSource: "",
        buildFailed: false,
        compilerOutput: nil,
        warnings: [],
        outcomes: [],
        passCount: 0,
        totalTests: 0,
        totalPoints: 0,
        earnedPoints: "0",
        rawEarnedPoints: 0,
        executionTimeMs: 0,
        gradePercent: 0,
        badgeContext: BadgeContext(
            attemptNumber: 1, gradePercent: 0, executionTimeMs: 0, priorGradePercent: nil),
        secretOutcomes: []
    )
}

// Internal (was private): produced by `loadPriorAttemptDelta` in
// WebRoutes+Submission.swift, consumed by `processDisplayResult` here.
/// Delta information harvested from the immediately-prior attempt.
struct PriorAttemptDelta {
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
    // The assignment's own language. The `record` above also keys on the
    // extension-stripped stem, and `runnerOutcomeTestName` reports that stem,
    // so the join survived this being Python-only — but only by accident of
    // which of the two keys the lookup happens to use. Naming the language
    // makes the filename key correct as well, so the map is not one refactor
    // of `outcomeTestName` away from silently losing every hint on every
    // non-Python assignment.
    let language = AssignmentLanguage.resolve(manifest: props, notebookData: nil) ?? .python
    for f in props.patternFamilies {
        for c in f.cases where c.enabled {
            record(
                generatedScriptFilename(
                    familyID: f.id, caseKey: c.key,
                    tier: c.resolvedTier(defaults: f.defaults),
                    language: language),
                c.resolvedHint(defaults: f.defaults))
        }
    }
    for chk in props.notebookChecks {
        record(
            generatedCheckFilename(checkID: chk.id, tier: chk.tier, language: language),
            chk.hint)
    }
    return map
}

// Internal (was private): produced by `loadManifestDisplayData` in
// WebRoutes+Submission.swift, consumed by the presentation pipeline here.
struct ManifestDisplayData {
    let displayNameMap: [String: String]
    let hintByFilename: [String: String]
    let sections: [TestSuiteSection]
    let entries: [TestSuiteEntry]
    /// Manifest-derived alias map for achievement `testPass` matching (audit
    /// A1): outcome test name → every name that suite entry answers to.
    let testNameAliases: [String: Set<String>]

    init(
        displayNameMap: [String: String],
        hintByFilename: [String: String],
        sections: [TestSuiteSection],
        entries: [TestSuiteEntry],
        testNameAliases: [String: Set<String>] = [:]
    ) {
        self.displayNameMap = displayNameMap
        self.hintByFilename = hintByFilename
        self.sections = sections
        self.entries = entries
        self.testNameAliases = testNameAliases
    }
}

// Internal (was private): constructed by `submissionPage` in
// WebRoutes+Submission.swift.
/// Viewer-side inputs that gate which tiers are itemized and whether release
/// output is shown.  The grade spans every tier regardless of these.
struct SubmissionViewer {
    let user: APIUser
    /// Whether the viewer is course staff (TA+ or admin) for this submission's
    /// course — gates secret-tier bucketing and instructor-level detail (#417
    /// Slice G, per-course; was the global `user.isInstructor`).
    let isStaff: Bool
    /// Tiers rendered as individual rows (public + release for students; all
    /// tiers for instructors).  Secret is itemized for students only when
    /// `secretRevealed`.
    let itemizedTiers: Set<String>
    /// Whether release-tier output is shown (true after the deadline / for
    /// instructors).  Release rows are listed by name either way.
    let releaseOutputVisible: Bool
    /// True when this student has spent their secret-reveal token on an
    /// assignment whose reveal option is enabled — secret rows are then
    /// itemized like public rows instead of aggregated.  Always false for
    /// staff (they itemize secret regardless).
    let secretRevealed: Bool
}

// Internal (was private): constructed by `submissionPage` in
// WebRoutes+Submission.swift.
/// Banner text shown above the outcomes table comparing this attempt against
/// the previous one.  `headerText` is nil when `hasDelta` is false.
struct DeltaBanner {
    let hasDelta: Bool
    let headerText: String?
}

// Internal: constructed by `submissionPage` in WebRoutes+Submission.swift.
/// Secret-reveal display state for the submission page.  `available` renders
/// the "spend your reveal token" offer box; `active` renders the "secret
/// tests revealed" info banner (and secret rows itemize via the viewer's
/// tier set).  Both are always false for staff.
struct SecretRevealBanner {
    let available: Bool
    let active: Bool
}

// Internal (was private): constructed by `submissionPage` in
// WebRoutes+Submission.swift.
/// Per-page decoration data attached to `SubmissionContext` — class-wide
/// achievement badges and the current user's display context.
struct SubmissionDecorations {
    let badges: [AchievementBadge]
    let currentUser: CurrentUserContext?
    /// Instructor override percent for this student × assignment, nil when
    /// none.  The effective grade shown above the autograded breakdown.
    let overrideGradePercent: Int?
    /// Class-goal progress views for the "Achievements" section.
    let classGoals: [ClassGoalView]
    /// Secret-reveal offer/active state for the reveal-token UI.
    let secretReveal: SecretRevealBanner
}
