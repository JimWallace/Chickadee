// APIServer/Services/SolutionResolver.swift
//
// The one place that finds an assignment's reference solution (#2488).
//
// Four functions used to search for it, over three different lists of places,
// and they disagreed: an assignment whose only solution was the unvalidated
// draft passed the `afterDue` guard and the reveal page served the draft, but
// MCP `get_solution` said there was no solution. Each caller now names the
// sources it accepts, and the order of the search is fixed here.

import Fluent
import Foundation
import Vapor

/// A place where a reference solution can live, in search order.
enum SolutionSource: CaseIterable, Sendable {
    /// A `solution.*` entry the instructor bundled in the setup zip.
    case setupZip
    /// The validation submission the assignment links to.
    case linkedValidation
    /// The newest validation submission for the setup.
    case newestValidation
    /// The unvalidated draft written by the editor's "create solution".
    case draft

    /// Every source, for the questions "is there a solution?" and "show me
    /// the solution".
    static let any: [SolutionSource] = allCases

    /// Only the validation submissions: the solution a validation run uses.
    static let validationRuns: [SolutionSource] = [.linkedValidation, .newestValidation]
}

/// The reference solution, where it was found.
struct ResolvedSolution: Sendable {
    let data: Data
    let filename: String
    let source: SolutionSource
}

/// Where to look: the setup, and the validation submission an assignment links
/// to. A draft setup with no assignment yet has no linked submission.
struct SolutionLocation: Sendable {
    let testSetupID: String
    let linkedValidationID: String?

    init(testSetupID: String, linkedValidationID: String?) {
        self.testSetupID = testSetupID
        self.linkedValidationID = linkedValidationID
    }

    init(_ assignment: APIAssignment) {
        self.init(testSetupID: assignment.testSetupID, linkedValidationID: assignment.validationSubmissionID)
    }
}

/// Finds the reference solution at `location` in the first of `sources` (taken
/// in `SolutionSource` order) that holds a non-empty file, or nil.
///
/// `setup` saves a lookup when the caller has it; without it the setup is
/// read only if `.setupZip` is searched.
func resolveSolution(
    at location: SolutionLocation,
    setup: APITestSetup? = nil,
    sources: [SolutionSource],
    db: any Database,
    testSetupsDirectory: String
) async throws -> ResolvedSolution? {
    for source in SolutionSource.allCases where sources.contains(source) {
        if let found = try await solution(
            in: source, location: location, setup: setup, db: db,
            testSetupsDirectory: testSetupsDirectory)
        {
            return found
        }
    }
    return nil
}

private func solution(
    in source: SolutionSource,
    location: SolutionLocation,
    setup: APITestSetup?,
    db: any Database,
    testSetupsDirectory: String
) async throws -> ResolvedSolution? {
    switch source {
    case .setupZip:
        let resolvedSetup: APITestSetup?
        if let setup {
            resolvedSetup = setup
        } else {
            resolvedSetup = try await APITestSetup.find(location.testSetupID, on: db)
        }
        guard let zipPath = resolvedSetup?.zipPath,
            let entry = await listZipEntries(zipPath: zipPath).first(where: { $0.hasPrefix("solution.") }),
            let data = await extractZipEntry(zipPath: zipPath, entryName: entry), !data.isEmpty
        else { return nil }
        return ResolvedSolution(data: data, filename: entry, source: source)
    case .linkedValidation:
        guard let validationID = location.linkedValidationID,
            let submission = try await APISubmission.find(validationID, on: db)
        else { return nil }
        return solution(from: submission, source: source)
    case .newestValidation:
        guard
            let submission = try await APISubmission.query(on: db)
                .filter(\.$testSetupID == location.testSetupID)
                .filter(\.$kind == APISubmission.Kind.validation)
                .sort(\.$submittedAt, .descending)
                .first()
        else { return nil }
        return solution(from: submission, source: source)
    case .draft:
        let path = draftSolutionNotebookPath(
            testSetupsDirectory: testSetupsDirectory, setupID: location.testSetupID)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { return nil }
        return ResolvedSolution(data: data, filename: "solution.ipynb", source: source)
    }
}

private func solution(from submission: APISubmission, source: SolutionSource) -> ResolvedSolution? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: submission.zipPath)), !data.isEmpty else {
        return nil
    }
    return ResolvedSolution(data: data, filename: submission.filename ?? "solution.ipynb", source: source)
}
