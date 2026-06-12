// APIServer/Utilities/NotebookCheckValidator.swift
//
// Validates a list of `NotebookCheck` records before they are applied
// to a test setup.  Mirrors `PatternFamilyValidator.swift` for the
// parallel concept.  Split out of `ManifestValidation.swift` in
// v0.4.182.

import Core
import Vapor

/// Validates a list of notebook checks before they are applied to a test
/// setup.  Mirrors `validatePatternFamilies` for the parallel concept.
///
/// Checks:
/// - `id` is unique across the assignment, is a valid filename fragment.
/// - `points` is non-negative.
/// - kind-specific required fields are present and well-formed
///   (e.g. `.dataFrameShape` requires a Python-identifier `variable` and
///   non-negative integer `expectedRows` / `expectedCols`).
/// - generated check filenames don't collide with hand-written scripts
///   or with pattern-family generated filenames.
///
/// The per-kind field validation is dispatched through
/// `notebookCheckKindHandler(for:)`; this function handles the
/// kind-agnostic checks (id, points) and the cross-check filename
/// collision pass.
func validateNotebookChecks(
    _ checks: [NotebookCheck],
    patternFamilies: [PatternFamily] = [],
    testSuites: [TestSuiteEntry] = []
) throws {
    var seenCheckIDs: Set<String> = []
    for check in checks {
        guard isValidIdentifierFragment(check.id) else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check id '\(check.id)' must contain only letters, digits, and underscore")
        }
        guard seenCheckIDs.insert(check.id).inserted else {
            throw Abort(
                .unprocessableEntity,
                reason: "Duplicate notebook check id '\(check.id)'")
        }
        guard check.points >= 0 else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check '\(check.id)': points must be non-negative")
        }

        try notebookCheckKindHandler(for: check.kind).validate(check)
    }

    // Filename collisions: every generated filename a check produces
    // (its test script + any sidecars like `_expected_<id>.csv`) must
    // not match a hand-written script or a pattern-family-generated
    // filename.  A future pattern family might generate the same name
    // as a future check; this catches that at save time so the runner
    // never sees a duplicate.
    let rawScripts = Set(testSuites.filter { !$0.isGenerated }.map(\.script))
    let familyFilenames = Set(patternFamilies.flatMap(patternFamilyAllGeneratedFilenames))
    var seenCheckFilenames: Set<String> = []
    for check in checks {
        for filename in notebookCheckAllGeneratedFilenames(check) {
            if rawScripts.contains(filename) {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' would generate '\(filename)', but a hand-written file with that name already exists. Rename the file or change the check id."
                )
            }
            if familyFilenames.contains(filename) {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' would generate '\(filename)', which collides with a pattern family's generated filename. Change the check id."
                )
            }
            if !seenCheckFilenames.insert(filename).inserted {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' would generate '\(filename)', which collides with another check's generated file. Change the check id."
                )
            }
        }
    }
}
