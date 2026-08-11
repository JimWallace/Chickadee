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

/// The upload-only-language coherence rule's message, shared by the
/// setup-upload API, the submission-mode editor and the MCP tools.
///
/// A FUNCTION OF THE LANGUAGE, not a constant. It was hardcoded C++ prose — and
/// the two call sites that had correctly generalised their *predicate* to
/// `editorSupport` still served it verbatim, so a Racket author who tripped the
/// rule was told about C++. The predicate and the wording have to generalise
/// together or the rule reads as a bug in whichever language is not C++.
func requiresUploadOnlyMessage(_ language: AssignmentLanguage) -> String {
    "A \(language.displayName) assignment is upload-only: \(language.displayName) has no "
        + "editor kernel or notebook workflow, so submissionMode must be \"uploadOnly\"."
}

/// True when this language has no editor kernel, so its assignments must be
/// upload-only.
///
/// The one spelling of the predicate. Written out as `== .cpp` at three of its
/// five enforcement sites until a second upload-only language shipped and none
/// of the three covered it; `editorSupport` is exhaustive, so a seventh
/// language cannot fail to answer it.
func requiresUploadOnlySubmission(_ language: AssignmentLanguage) -> Bool {
    if case .uploadOnly = language.editorSupport { return true }
    return false
}

/// The same question asked of a manifest's recorded `language` string, for the
/// sites that hold raw manifest JSON rather than a decoded `TestProperties`.
/// An unrecognised or absent value is not upload-only — it is not a language
/// this build knows, and refusing on it would block an author over a field they
/// cannot see.
func manifestRequiresUploadOnlySubmission(_ manifest: String?) -> AssignmentLanguage? {
    guard let raw = currentManifestLanguage(manifest),
        let language = AssignmentLanguage(rawValue: raw),
        requiresUploadOnlySubmission(language)
    else { return nil }
    return language
}

/// Reads the recorded `language` straight from a manifest JSON string, or nil
/// when none is recorded (or the manifest can't be parsed).
func currentManifestLanguage(_ manifest: String?) -> String? {
    guard let manifest,
        let dict = (try? JSONSerialization.jsonObject(with: Data(manifest.utf8))) as? [String: Any]
    else { return nil }
    return dict["language"] as? String
}

/// Sets the test setup's recorded `language` to `language` when it differs.
/// Returns the effective language.
///
/// The recorded field is normally a *memo* of what resolution derived from the
/// content (`manifestWithRederivedLanguage`), which is why nothing else writes
/// it directly. An upload-only language is the case that memo cannot reach: with
/// no editor kernel there is no notebook kernelspec to imply it, and C++'s
/// generated tests are extension-free `.sh` wrappers by design — leaving a
/// declaration as the only signal there is. Hence this setter, and hence its two
/// guards.
///
/// Refuses an upload-only language while the setup is still in notebook mode:
/// the mirror of `setManifestSubmissionMode`'s guard, so the incoherent
/// combination cannot be authored from either direction.
///
/// Refuses any change once generated scripts exist. A language change rewrites
/// every generated filename (the extension is part of the name), and only the
/// pattern-family application path knows how to re-render and clean up the old
/// side. Rather than half-perform that here, the change is confined to a suite
/// with nothing generated in it yet — which is where an author declares the
/// language anyway.
func setManifestLanguage(
    setup: APITestSetup, to language: String, on db: any Database
) async throws -> String {
    guard let parsed = AssignmentLanguage(rawValue: language) else {
        throw AppError.badRequest(reason: unknownLanguageMessage(language))
    }
    let current = currentManifestLanguage(setup.manifest)
    guard current != language else { return language }
    if requiresUploadOnlySubmission(parsed),
        currentManifestSubmissionMode(setup.manifest) != SubmissionMode.uploadOnly.rawValue
    {
        throw AppError.badRequest(reason: requiresUploadOnlyMessage(parsed))
    }
    if manifestHasGeneratedScripts(setup.manifest) {
        throw AppError.badRequest(reason: languageChangeAfterGenerationMessage)
    }
    try await mutateManifest(setup: setup, on: db) { dict in
        dict["language"] = language
    }
    return language
}

/// The wire value meaning "this assignment has no language — its suite is plain
/// shell scripts". Shared by the web creation/edit selects and the MCP tools so
/// the two surfaces cannot disagree about how the choice is spelled.
///
/// A reserved STRING at the surface, not an `AssignmentLanguage` case: the enum
/// promises a literal renderer, an inputs file, pattern families and a
/// personalization driver, none of which a shell suite has. A case would have to
/// answer "not applicable" to all of them while silently satisfying every
/// exhaustive switch.
let noLanguageChoice = "none"

/// Parses a creation-time or edit-time language choice into the language to
/// record — nil for `noLanguageChoice`.
func parseLanguageChoice(_ raw: String) throws -> AssignmentLanguage? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed == noLanguageChoice { return nil }
    guard let parsed = AssignmentLanguage(rawValue: trimmed) else {
        throw AppError.badRequest(reason: unknownLanguageMessage(raw))
    }
    return parsed
}

/// Records an author's answer to "what language is this assignment?" — the
/// language itself, or its declared absence, plus the flag saying the question
/// was answered at all.
///
/// This is the declaration primitive, distinct from `setManifestLanguage`
/// (which edits a language on an assignment that already has content and guards
/// accordingly). Two differences matter:
///
/// 1. It records `languageDeclared`, so a nil language afterwards means "the
///    author says there is none" rather than "nobody has been asked".
/// 2. An upload-only language sets `submissionMode` AND `gradingMode` too,
///    because the language implies both. That is what makes declare-at-creation
///    possible for C++ at all: `setManifestLanguage` refuses an upload-only
///    language while the setup is in notebook mode, and a brand-new assignment
///    always is — so requiring the declaration up front would otherwise leave
///    C++ uncreatable. It also collapses the old three-step authoring dance
///    (grading mode, then submission mode, then language) into one answer.
///
///    `gradingMode` must move with it. A new assignment defaults to `browser`,
///    so setting only `submissionMode` left the manifest holding
///    `uploadOnly` + `browser` — the pair `TestSetupRoutes` calls incoherent and
///    refuses on the zip path, and that `setManifestGradingMode` and
///    `set_submission_mode` both refuse to store. Creation was the one
///    authoring surface that could still produce it, so a freshly created C++
///    assignment read back `gradingMode: "browser"` from `get_assignment`.
///    Grading itself was never wrong (`TestProperties.effectiveGradingMode`
///    coerces upload-only to `.worker` at consumption), which is exactly why
///    this survived: the stored value was misreported, not misused.
func declareManifestLanguage(
    setup: APITestSetup, to language: AssignmentLanguage?, on db: any Database
) async throws {
    try await mutateManifest(setup: setup, on: db) { dict in
        dict["languageDeclared"] = true
        guard let language else {
            dict.removeValue(forKey: "language")
            return
        }
        dict["language"] = language.rawValue
        if case .uploadOnly = language.editorSupport {
            dict["submissionMode"] = SubmissionMode.uploadOnly.rawValue
            dict["gradingMode"] = GradingMode.worker.rawValue
        }
    }
}

/// Removes the recorded `language`, returning the assignment to derived
/// resolution. Returns true when a value was actually removed.
///
/// The escape hatch from the one-way door `AssignmentLanguage.rederive`
/// documents: a recorded language outranks every content signal, so without a
/// way back an assignment declared wrong once would keep rendering in that
/// language forever, however its notebook and scripts changed underneath.
///
/// Guarded exactly like `setManifestLanguage`, and for the same reason: clearing
/// changes which language generated tests render in just as setting does, and
/// only the pattern-family application path knows how to re-render and clean up
/// the old side.
func clearManifestLanguage(setup: APITestSetup, on db: any Database) async throws -> Bool {
    guard currentManifestLanguage(setup.manifest) != nil else { return false }
    if manifestHasGeneratedScripts(setup.manifest) {
        throw AppError.badRequest(reason: languageChangeAfterGenerationMessage)
    }
    try await mutateManifest(setup: setup, on: db) { dict in
        dict.removeValue(forKey: "language")
    }
    return true
}

/// True when the manifest carries any generated test — a pattern-family case or
/// a notebook check. Read off `generatedBy` rather than the family/check lists
/// so a family that has produced no enabled case doesn't block a change that
/// would rewrite nothing.
func manifestHasGeneratedScripts(_ manifest: String?) -> Bool {
    guard let manifest,
        let dict = (try? JSONSerialization.jsonObject(with: Data(manifest.utf8))) as? [String: Any],
        let suites = dict["testSuites"] as? [[String: Any]]
    else { return false }
    return suites.contains { $0["generatedBy"] != nil }
}

/// Names the languages rather than listing an enum case, so the message stays
/// correct when a sixth language is added.
func unknownLanguageMessage(_ given: String) -> String {
    let known = AssignmentLanguage.allCases.map(\.rawValue).sorted().joined(separator: ", ")
    return "Unknown assignment language \"\(given)\". Known languages: \(known)."
}

/// Shared by the MCP tool and any future surface that declares the language.
let languageChangeAfterGenerationMessage =
    "This assignment already has generated tests, whose filenames carry the current language's "
    + "extension. Declare the language before authoring pattern families or notebook checks, or "
    + "delete the generated families/checks first."

/// Refusal for a save that would GENERATE a test script on an assignment whose
/// author declared no language.
///
/// A generated script is written in a language, so this question cannot answer
/// "none" the way resolution can. The old behaviour rendered Python, justified
/// by a circularity that only existed while the language was inferred from
/// content ("a family is often the first thing authored, so there is no graded
/// script to sniff yet"). Every door that creates an assignment declares now,
/// so nil means the author chose None and there is nothing to wait for.
///
/// Deliberately an authoring-time refusal. Nothing on the grading path refuses
/// for want of a declaration: an instructor can fix this from the dropdown, and
/// a student cannot fix it at all.
let undeclaredLanguageGenerationMessage =
    "This assignment declares no language, so there is no syntax to generate a test in. "
    + "Set the assignment's language before adding pattern families or notebook checks — "
    + "an assignment set to \"None\" can hold hand-written shell scripts only."

/// Refusal for a save that would store a per-student `=` expression on an
/// assignment whose author declared no language.
///
/// Same rule as `undeclaredLanguageGenerationMessage`, one step further out: an
/// expression is source code, so it needs a language the way a generated script
/// does. The refusal lives on the save; notebook substitution at student
/// first-open keeps its stated default and never refuses.
let undeclaredLanguageExpressionMessage =
    "This assignment declares no language, so a per-student `=` expression has no interpreter "
    + "to run in. Set the assignment's language before adding expressions — literal variables "
    + "work without one."

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
    // The coherence rule from the other direction: an instructor cannot flip
    // an upload-only language back to the notebook workflow it does not have.
    // Asked of `editorSupport` rather than spelled `== .cpp`, which is what let
    // Racket through here.
    if mode == SubmissionMode.notebook.rawValue,
        let language = manifestRequiresUploadOnlySubmission(setup.manifest)
    {
        throw AppError.badRequest(reason: requiresUploadOnlyMessage(language))
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
