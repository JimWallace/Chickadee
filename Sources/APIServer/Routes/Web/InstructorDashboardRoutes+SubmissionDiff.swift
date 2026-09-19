// APIServer/Routes/Web/InstructorDashboardRoutes+SubmissionDiff.swift
//
// The starter-to-submission diff page
// (GET /instructor/:assignmentID/submissions/:submissionID/diff): what a
// student changed, cell by cell for a notebook, line by line for a single
// source file, against the assignment's starter. Instructor test cells are
// dropped from BOTH sides — they are the instructor's, not the student's —
// so a hidden test never appears as an "added" block.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/:assignmentID/submissions/:submissionID/diff

    @Sendable
    func submissionDiffPage(req: Request) async throws -> View {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        guard
            let submissionID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(submissionID, on: req.db),
            // Both checks: the :submissionID segment must not be drivable
            // across assignments, and a validation run is not student work.
            submission.testSetupID == assignment.testSetupID,
            submission.kind == APISubmission.Kind.student
        else {
            throw WebAssignmentError.notFound(resource: "Submission")
        }
        let student: APIUser? =
            if let userID = submission.userID {
                try await APIUser.find(userID, on: req.db)
            } else {
                nil
            }

        // Primitives only across the thread-pool hop (#1158).
        let source = SubmissionDiffSource(
            artifactPath: submission.zipPath,
            submittedFilename: submission.filename,
            starter: NotebookSourceRef(setup),
            setupZipPath: setup.zipPath)
        let sides = await submissionDiffSides(source)

        let rows = LineDiff.unified(old: sides.oldLines, new: sides.newLines, context: 3)
        let counts = LineDiff.counts(rows)
        let assignmentIDRaw = assignment.publicID
        let historyURL = submission.userID.map {
            "/instructor/\(assignmentIDRaw)/students/\($0.uuidString)/history"
        }
        return try await req.view.render(
            "submission-diff",
            SubmissionDiffContext(
                currentUser: req.currentUserContext,
                assignmentID: assignmentIDRaw,
                assignmentTitle: assignment.title,
                studentID: student?.username ?? "unknown",
                attemptNumber: submission.attemptNumber ?? 1,
                comparedLabel: sides.comparedLabel,
                unavailableReason: sides.unavailableReason,
                addedCount: counts.added,
                removedCount: counts.removed,
                rows: rows.map(SubmissionDiffRowView.init),
                resultsURL: "/submissions/\(submissionID)",
                historyURL: historyURL ?? "/instructor/\(assignmentIDRaw)/submissions"
            )
        )
    }
}

// MARK: - Loading both sides

/// What the diff loader needs, reduced to Sendable primitives.
struct SubmissionDiffSource: Sendable {
    let artifactPath: String
    let submittedFilename: String?
    let starter: NotebookSourceRef
    let setupZipPath: String
}

/// The two texts under comparison, or the reason there are none.
struct SubmissionDiffSides: Sendable, Equatable {
    let oldLines: [String]
    let newLines: [String]
    /// "assignment.ipynb", "warmup.py", … — what the two sides are.
    let comparedLabel: String
    /// Set when the submission has no comparable text (a zip with no
    /// notebook, an unreadable artifact); the page shows this instead of a
    /// listing.
    let unavailableReason: String?
}

/// The marker line emitted between notebook cells so the listing shows where
/// one cell ends and the next begins. Deliberately carries no cell number:
/// inserting a cell would otherwise renumber every marker after it and make
/// the whole tail read as changed.
let notebookDiffCellMarker = "── cell ──"

func submissionDiffSides(_ source: SubmissionDiffSource) async -> SubmissionDiffSides {
    let artifact = URL(fileURLWithPath: source.artifactPath)
    let submittedName = source.submittedFilename ?? artifact.lastPathComponent
    let ext = (artifact.pathExtension.isEmpty ? (submittedName as NSString).pathExtension : artifact.pathExtension)
        .lowercased()
    guard let bytes = try? Data(contentsOf: artifact) else {
        return SubmissionDiffSides(
            oldLines: [], newLines: [], comparedLabel: submittedName,
            unavailableReason: "The submitted file is no longer on disk.")
    }

    var submittedNotebook: Data?
    if ext == "ipynb" || submittedName.lowercased().hasSuffix(".ipynb") {
        submittedNotebook = bytes
    } else if ext == "zip" {
        submittedNotebook = await extractNotebookFromZip(zipPath: source.artifactPath)
        guard submittedNotebook != nil else {
            return SubmissionDiffSides(
                oldLines: [], newLines: [], comparedLabel: submittedName,
                unavailableReason:
                    "A zip submission with no notebook cannot be compared. Download it to review the files.")
        }
    }

    if let submittedNotebook {
        guard let newCells = NotebookCellSources.cells(from: submittedNotebook) else {
            return SubmissionDiffSides(
                oldLines: [], newLines: [], comparedLabel: submittedName,
                unavailableReason: "The submitted notebook could not be parsed.")
        }
        let oldCells = await (try? notebookData(from: source.starter)).flatMap(NotebookCellSources.cells(from:)) ?? []
        return SubmissionDiffSides(
            oldLines: notebookDiffLines(oldCells),
            newLines: notebookDiffLines(newCells),
            comparedLabel: "starter notebook → \(submittedName)",
            unavailableReason: nil)
    }

    // A single source file: compare against the starter file of the same
    // name inside the test setup zip, if the instructor shipped one.
    guard let newText = String(bytes: bytes, encoding: .utf8) else {
        return SubmissionDiffSides(
            oldLines: [], newLines: [], comparedLabel: submittedName,
            unavailableReason: "The submitted file is not UTF-8 text, so it cannot be compared.")
    }
    let starterEntry = await listZipEntries(zipPath: source.setupZipPath).first {
        ($0 as NSString).lastPathComponent == submittedName
    }
    var oldText: String?
    if let starterEntry,
        let bytes = await extractZipEntry(zipPath: source.setupZipPath, entryName: starterEntry)
    {
        oldText = String(bytes: bytes, encoding: .utf8)
    }
    return SubmissionDiffSides(
        oldLines: oldText.map(diffLines) ?? [],
        newLines: diffLines(newText),
        comparedLabel: oldText == nil
            ? "\(submittedName) (no starter file of that name; every line is new)"
            : "starter \(submittedName) → submitted \(submittedName)",
        unavailableReason: nil)
}

/// A notebook flattened to lines for diffing: every non-test cell behind one
/// marker line. Markdown cells are kept — a student's written answer is as
/// much their work as their code.
func notebookDiffLines(_ cells: [[String: Any]]) -> [String] {
    var lines: [String] = []
    for cell in cells where !isTestCell(cell) {
        lines.append(notebookDiffCellMarker)
        lines.append(contentsOf: diffLines(NotebookCellSources.cellSource(cell)))
    }
    return lines
}

/// Splits text into lines, dropping one trailing newline so a file that
/// ends in a newline does not diff as having a phantom empty last line.
func diffLines(_ text: String) -> [String] {
    var body = text
    if body.hasSuffix("\n") { body.removeLast() }
    return body.isEmpty ? [] : body.components(separatedBy: "\n")
}

// MARK: - Template context

struct SubmissionDiffContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let studentID: String
    let attemptNumber: Int
    let comparedLabel: String
    let unavailableReason: String?
    let addedCount: Int
    let removedCount: Int
    let rows: [SubmissionDiffRowView]
    let resultsURL: String
    let historyURL: String
}

/// One listing row, with its kind spelled as flags the template branches on
/// (Leaf cannot compare an enum's raw value in a class attribute safely).
struct SubmissionDiffRowView: Encodable {
    let isAdded: Bool
    let isRemoved: Bool
    let isFold: Bool
    /// True for the cell-boundary marker line, styled muted.
    let isMarker: Bool
    let oldNumber: String
    let newNumber: String
    let text: String

    init(_ row: LineDiffRow) {
        isAdded = row.kind == .added
        isRemoved = row.kind == .removed
        isFold = row.kind == .fold
        isMarker = row.kind != .fold && row.text == notebookDiffCellMarker
        oldNumber = row.kind == .fold ? "" : row.oldNumber.map(String.init) ?? ""
        newNumber = row.kind == .fold ? "" : row.newNumber.map(String.init) ?? ""
        text = row.text
    }
}
