// APIServer/Helpers/ManifestFieldEdits.swift
//
// Single-field manifest edits shared across surfaces (#1121): the MCP tools
// (`set_grading_mode`, `set_time_limit`, `author_script`,
// `set_assignment_course_section`) and the web section-adoption path
// (`CourseAdminRoutes+Sections`) all mutate exactly one JSON field on
// `test_setups.manifest`.  Each helper is a `mutateManifest` closure
// (SuiteEditHelpers.swift) so the parse → mutate → sorted-keys re-serialise →
// save pattern lives once; unknown fields the server doesn't model survive
// the round trip.  Helpers save only when the field actually changes, so a
// no-op call doesn't bump the row.  Unlike the pre-#1121 copies (which
// silently skipped the write), a manifest that isn't a JSON object now
// throws — that indicates a corrupted setup, not a user error.

import Core
import Fluent
import Foundation

/// Reads the `gradingMode` field straight from a manifest JSON string without
/// round-tripping `TestProperties`, defaulting to "worker" (TestProperties' own
/// default) when the field is absent or the manifest can't be parsed — so every
/// tool reports the same effective mode `get_assignment` does.
func currentManifestGradingMode(_ manifest: String?) -> String {
    guard let manifest,
        let dict = (try? JSONSerialization.jsonObject(with: Data(manifest.utf8))) as? [String: Any]
    else { return "worker" }
    return (dict["gradingMode"] as? String) ?? "worker"
}

/// Sets the test setup's `gradingMode` to `mode` when it differs.  Returns the
/// effective mode.
///
/// Refuses `browser` on an upload-mode setup: an upload assignment has no
/// notebook page to host the browser runner, so the stored value could never
/// execute (`TestProperties.effectiveGradingMode` would pin it to worker
/// anyway — the refusal keeps the stored state honest rather than silently
/// inert).  The section-adoption paths check the submission mode first and
/// skip the sync, so this guard only fires on an explicit request.
func setManifestGradingMode(
    setup: APITestSetup, to mode: String, on db: any Database
) async throws -> String {
    if mode == GradingMode.browser.rawValue,
        currentManifestSubmissionMode(setup.manifest) == SubmissionMode.uploadOnly.rawValue
    {
        throw AppError.badRequest(
            reason: uploadModeGradingConflictMessage)
    }
    if currentManifestGradingMode(setup.manifest) != mode {
        try await mutateManifest(setup: setup, on: db) { dict in
            dict["gradingMode"] = mode
        }
    }
    return mode
}

/// The one message both halves of the upload/browser refusal use, so the web
/// form banner and the MCP tool error stay identical.
let uploadModeGradingConflictMessage =
    "An upload-only assignment is graded by the native worker; it cannot use browser grading. "
    + "Switch the grading mode to \"worker\" first."

/// Reads the `submissionMode` field straight from a manifest JSON string,
/// defaulting to "notebook" (TestProperties' own default) when the field is
/// absent or the manifest can't be parsed.
func currentManifestSubmissionMode(_ manifest: String?) -> String {
    guard let manifest,
        let dict = (try? JSONSerialization.jsonObject(with: Data(manifest.utf8))) as? [String: Any]
    else { return SubmissionMode.notebook.rawValue }
    return (dict["submissionMode"] as? String) ?? SubmissionMode.notebook.rawValue
}

/// Sets the test setup's `submissionMode` to `mode` when it differs.  Returns
/// the effective mode.  Refuses `upload` while the setup is browser-graded —
/// the mirror of `setManifestGradingMode`'s guard, so the incoherent
/// combination cannot be authored from either direction.
func setManifestSubmissionMode(
    setup: APITestSetup, to mode: String, on db: any Database
) async throws -> String {
    if mode == SubmissionMode.uploadOnly.rawValue,
        currentManifestGradingMode(setup.manifest) == GradingMode.browser.rawValue
    {
        throw AppError.badRequest(
            reason: uploadModeGradingConflictMessage)
    }
    if currentManifestSubmissionMode(setup.manifest) != mode {
        try await mutateManifest(setup: setup, on: db) { dict in
            dict["submissionMode"] = mode
        }
    }
    return mode
}

/// Adds or removes `filename` in the manifest's `graderOnlyFiles` list, saving
/// only when it actually changes.  A grader-only file is bundled for the worker
/// but withheld from every student-facing path — see docs/datasets.md.
func setManifestGraderOnly(
    setup: APITestSetup, filename: String, graderOnly: Bool, on db: any Database
) async throws {
    let dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any]
    let present = ((dict?["graderOnlyFiles"] as? [String]) ?? []).contains(filename)
    guard graderOnly != present else { return }  // already in the desired state
    try await mutateManifest(setup: setup, on: db) { dict in
        var files = (dict["graderOnlyFiles"] as? [String]) ?? []
        if graderOnly {
            files.append(filename)
        } else {
            files.removeAll { $0 == filename }
        }
        dict["graderOnlyFiles"] = files
    }
}

/// Sets the test setup's default `timeLimitSeconds` to `seconds` when it
/// differs.  Returns the effective value.
func setManifestTimeLimitSeconds(
    setup: APITestSetup, to seconds: Int, on db: any Database
) async throws -> Int {
    let dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any]
    if (dict?["timeLimitSeconds"] as? Int) != seconds {
        try await mutateManifest(setup: setup, on: db) { dict in
            dict["timeLimitSeconds"] = seconds
        }
    }
    return seconds
}

/// Sets (or clears) the test setup's `minimumRunnerVersion` gate, saving only
/// when it actually changes.  A blank/nil `version` clears the gate (the key is
/// removed, matching `TestProperties.encodeIfPresent` which omits a nil value).
/// A gated setup is only handed to a native runner whose advertised version is
/// `>=` this value — see docs/runner-capability-profiles.md.  Returns the
/// effective value (nil when cleared).
func setManifestMinimumRunnerVersion(
    setup: APITestSetup, to version: String?, on db: any Database
) async throws -> String? {
    let normalized = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effective = (normalized?.isEmpty == false) ? normalized : nil
    let dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any]
    guard (dict?["minimumRunnerVersion"] as? String) != effective else { return effective }
    try await mutateManifest(setup: setup, on: db) { dict in
        if let effective {
            dict["minimumRunnerVersion"] = effective
        } else {
            dict.removeValue(forKey: "minimumRunnerVersion")
        }
    }
    return effective
}
