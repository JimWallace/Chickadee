// APIServer/Helpers/ClassCorpus.swift
//
// The synthetic class corpus (docs/collaborative-class-assignments.md, Phase
// 4): every contributor's slot cells assembled into ONE notebook, owned by no
// student, graded once. Its grade is the class's coverage number — the thing
// a union of per-item rows cannot produce, because no row can say what
// fraction of a reference a combined test corpus exercises.
//
// WHY THE CORPUS IS A SUBMISSION. It needs the whole grading path: the setup
// zip, the language's extraction, a runner with the right interpreter, the
// script contract. Every one of those already hangs off a submission, and
// `kind == .validation` already proves a server-initiated submission owned by
// no student works end to end. So the corpus is `kind == .classAggregate`,
// enqueued the same way, claimed by the native worker after everything a human
// is waiting on, and read back through the ordinary result report.
//
// THE COVERAGE NUMBER IS THE RUN'S GRADE. Nothing new is asked of the script
// contract: the suite runs over the corpus and the collection's grade fraction
// is the coverage. A bug hunt's per-variant drivers answer "how many of the
// seeded bugs does the class's combined test file find"; a coverage-tool entry
// answers "what fraction of the reference do they exercise". Both are the
// existing contract read at the class level, which is why this slice adds no
// runner code, no manifest field and no new footer key.
//
// IT DOES NOT CALL `mergeNotebook`. That function applies the per-student slot
// bound, so passing N students' contributions through it would truncate the
// corpus to one student's worth of cells. The cells it assembles were already
// bounded — at submission time, by that same function — so the bound has been
// applied exactly once per contributor, which is what it is for.

import Core
import Fluent
import Foundation
import Vapor

/// A corpus ready to grade: the assembled notebook and who contributed to it.
struct ClassCorpus {
    let notebook: Data
    /// Contributors in ascending id order, one entry per student who put at
    /// least one non-empty slot cell in.
    let contributors: [UUID]
}

/// Assembles the class corpus for one assignment, or nil when there is nothing
/// to assemble.
///
/// Returns nil for every ordinary assignment: a corpus only exists where the
/// instructor's starter notebook declares contribution slots, which is the same
/// gate `recordClassItemCoverage` uses and the same one that makes the mere
/// existence of these rows say "this is a contribution assignment".
///
/// Returns nil for a PERSONALIZED assignment too. A corpus is one artifact
/// graded once, and a per-student assignment has no single set of inputs to
/// grade it against — every contributor wrote their tests against their own
/// material. Grading the corpus under one student's seed would report a number
/// about nobody. Stated rather than silently approximated.
///
/// Deterministic: contributors are ordered by user id, so the same set of
/// latest submissions always assembles the same bytes. Ordering by submission
/// time would reshuffle the corpus every time anybody resubmitted, which makes
/// two runs incomparable for no gain.
func assembleClassCorpus(
    setup: APITestSetup, app: Application, on db: Database
) async throws -> ClassCorpus? {
    guard let manifest = setup.decodedManifest(),
        !manifest.variesPerStudent,
        let instructorData = try? await app.notebookBytesCache.notebookData(
            for: NotebookSourceRef(setup)),
        let instructorCells = NotebookCellSources.cells(from: instructorData)
    else { return nil }

    let slotCount = NotebookContributionSlots.declaredSlotCount(inInstructorCells: instructorCells)
    guard slotCount > 0 else { return nil }

    // Roster-scoped, which is not negotiable: an instructor's own test
    // submission is a submission like any other, and a corpus that swept it in
    // would report the reference solution's coverage as the class's.
    let latestByUser = try await latestStudentSubmissionsByUser(setup: setup, on: db)
    guard !latestByUser.isEmpty else { return nil }

    var contributed: [(user: UUID, cells: [[String: Any]])] = []
    for userID in latestByUser.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        guard let submission = latestByUser[userID],
            submission.filename?.lowercased().hasSuffix(".ipynb") == true,
            let data = try? await runBlocking(
                app: app,
                {
                    try Data(contentsOf: URL(fileURLWithPath: submission.zipPath))
                }),
            let cells = NotebookCellSources.cells(from: data)
        else { continue }
        // The stored notebook is the MERGED one, so its non-test cells are
        // already this student's bounded contribution. Filtering again is
        // idempotent and covers a submission stored before slots existed.
        let slots = NotebookContributionSlots.retainedStudentCells(
            cells.filter { !isTestCell($0) }, limit: slotCount
        ).filter { !NotebookCellSources.cellSource($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !slots.isEmpty else { continue }
        contributed.append((user: userID, cells: slots))
    }
    guard !contributed.isEmpty else { return nil }

    guard var corpus = (try? JSONSerialization.jsonObject(with: instructorData)) as? [String: Any]
    else { return nil }
    corpus["cells"] = contributed.flatMap(\.cells) + instructorCells.filter(isTestCell)
    // `.sortedKeys` is what makes "the same inputs give the same bytes" true.
    // Without it every object's keys come out in whatever order the parse
    // produced, so two assemblies of an unchanged corpus differ byte for byte —
    // which makes two runs incomparable and re-hashes an artifact that did not
    // change.
    guard let bytes = try? JSONSerialization.data(withJSONObject: corpus, options: [.sortedKeys])
    else { return nil }
    return ClassCorpus(notebook: bytes, contributors: contributed.map(\.user))
}

/// Enqueues a corpus run for `setupID`, best-effort.
///
/// DEBOUNCED the same way validation is: a run already in flight is left to do
/// the job. Every result on a contribution assignment reaches this, so a
/// deadline spike would otherwise queue one corpus run per submission, each
/// grading a corpus that the next one supersedes. The in-flight run assembles
/// what existed when it was enqueued; the next contribution after it lands
/// starts the next one.
///
/// Never throws out. A corpus run is a diagnostic the class reads, and failing
/// a student's result report to schedule one is not a trade worth making.
func scheduleClassCorpusRun(
    setupID: String, app: Application, on db: Database, logger: Logger
) async {
    do {
        let inFlight = try await APIClassCoverageRun.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$completedAt == nil)
            .first()
        if inFlight != nil { return }

        // OPT-IN: only an assignment that ASKS for the number pays for it. The
        // corpus is a whole extra grading job per contribution burst, and a
        // number nobody reads is runner time taken from students. A
        // `classCoverage` goal on the manifest is the ask, and it is also the
        // only thing that renders the result — so gating here means the run
        // exists exactly where it is visible.
        guard let setup = try await APITestSetup.find(setupID, on: db),
            setup.decodedManifest()?.achievements.contains(where: \.isCoverageClassGoal) == true,
            let corpus = try await assembleClassCorpus(setup: setup, app: app, on: db)
        else { return }

        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let filePath = app.submissionsDirectory + "\(subID).ipynb"
        let notebook = corpus.notebook
        try await runBlocking(app: app) {
            try notebook.write(to: URL(fileURLWithPath: filePath))
        }

        let submission = APISubmission(
            id: subID,
            testSetupID: setupID,
            zipPath: filePath,
            attemptNumber: 1,
            filename: "class-corpus.ipynb",
            // Owned by nobody. Every listing, aggregate and grade selection
            // filters on `student`, so the corpus is invisible to all of them,
            // and a nil `userID` means it cannot be attributed to a student
            // even by a path that forgets to filter.
            userID: nil,
            kind: APISubmission.Kind.classAggregate)
        // Reuses the validation materialization so the corpus follows exactly
        // the path a server-initiated submission already takes. A corpus is
        // only assembled for a non-personalized assignment, so this resolves
        // nothing and leaves the row un-materialized — which is the correct
        // state for it, and the token is still what makes the save safe.
        let materialized = await materializeValidationGrading(
            submission: submission,
            setupID: setupID,
            templateNotebookData: corpus.notebook,
            testSetupsDirectory: app.testSetupsDirectory,
            app: app,
            on: db)
        try await materialized.saveClaimable(on: db)

        try await APIClassCoverageRun(
            testSetupID: setupID, submissionID: subID, contributors: corpus.contributors
        ).save(on: db)
        logger.info(
            "Class corpus run \(subID) enqueued for setup \(setupID) with \(corpus.contributors.count) contributor(s)"
        )
    } catch {
        logger.warning("scheduleClassCorpusRun for \(setupID): \(String(describing: error))")
    }
}

/// Completes the run a corpus submission's result belongs to.
///
/// A build failure completes the run with NO coverage rather than with zero. A
/// corpus that could not compile — one contributor's cell referring to a name
/// nobody defined is enough — says nothing about what the class covers, and
/// recording it as zero would drop a live progress bar to nothing until the
/// next contribution arrives. The run still completes, so the debounce
/// releases and the next contribution tries again.
func recordClassCoverageRun(
    submission: APISubmission, collection: TestOutcomeCollection, on db: Database
) async throws {
    guard submission.kind == APISubmission.Kind.classAggregate,
        let subID = submission.id,
        let run = try await APIClassCoverageRun.query(on: db)
            .filter(\.$submissionID == subID)
            .first()
    else { return }
    // The run's own grade fraction, taken from the points rather than from
    // `gradePercent`, which rounds to a whole percent — a coverage number is
    // reported to a tenth and rounding it here would be a loss no reader can
    // undo. A suite worth no points covers nothing measurable, so the run
    // completes with no number.
    if collection.buildStatus == .passed, collection.totalPoints > 0 {
        run.coverage = max(0, min(1, collection.earnedPoints / Double(collection.totalPoints)))
    }
    run.completedAt = Date()
    try await run.save(on: db)
}

/// The newest run that produced a coverage number for `testSetupID`, or nil
/// when none has.
///
/// Newest COMPLETED, deliberately: a queued run has no number, and reading it
/// would blank a progress bar that freezes into a grade push. The answer to
/// "the goal reads the latest aggregate only" is this one query.
func latestClassCoverageRun(
    testSetupID: String, on db: Database
) async throws -> APIClassCoverageRun? {
    try await APIClassCoverageRun.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$coverage != nil)
        .sort(\.$completedAt, .descending)
        .first()
}
