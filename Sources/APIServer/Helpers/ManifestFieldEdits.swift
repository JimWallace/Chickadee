// APIServer/Helpers/ManifestFieldEdits.swift
//
// Single-field manifest edits shared across surfaces (#1121): the MCP tools
// (`set_grading_mode`, `set_time_limit`, `author_script`,
// `set_assignment_course_section`) and the web section-adoption path
// (`CourseAdminRoutes+Sections`) all change exactly one field of
// `test_setups.manifest`.  Each helper is a `mutateManifest` closure
// (SuiteEditHelpers.swift) over the decoded `TestProperties`, so the decode →
// mutate → stable-encode → save pattern lives once.  Helpers save only when
// the field actually changes, so a no-op call doesn't bump the row.  A
// manifest that does not decode throws — that indicates a corrupted setup,
// not a user error.

import Core
import Fluent
import Foundation

/// Reads the `gradingMode` of a manifest JSON string, defaulting to "worker"
/// (TestProperties' own default) when the manifest can't be decoded — so every
/// tool reports the same effective mode `get_assignment` does.
func currentManifestGradingMode(_ manifest: String?) -> String {
    (manifest.flatMap(decodeManifest(fromJSON:))?.gradingMode ?? .worker).rawValue
}

/// Reads the `graderOnlyFiles` list of a manifest JSON string — empty when
/// the manifest can't be decoded.
func currentManifestGraderOnlyFiles(_ manifest: String?) -> [String] {
    manifest.flatMap(decodeManifest(fromJSON:))?.graderOnlyFiles ?? []
}

/// Sets the test setup's `gradingMode` to `mode` when it differs.  Returns the
/// effective mode.
///
/// Refuses `browser` on an upload-mode setup: an upload assignment has no
/// notebook page to host the browser runner, so the stored value could never
/// execute (`TestProperties.effectiveGradingMode` would pin it to worker
/// anyway — the refusal keeps the stored state honest rather than silently
/// inert).  Also refuses `browser` while the manifest marks grader-only
/// files: browser grading ships the whole setup workspace into the student's
/// kernel, which is exactly what a grader-only mark exists to prevent —
/// `author_script` refuses the same combination from the other side.  The
/// section-adoption paths check both conditions first and skip the sync, so
/// these guards only fire on an explicit request.
func setManifestGradingMode(
    setup: APITestSetup, to mode: String, on db: any Database
) async throws -> String {
    guard let parsed = GradingMode(rawValue: mode) else {
        throw AppError.badRequest(reason: "Unknown grading mode \"\(mode)\".")
    }
    if parsed == .browser,
        currentManifestSubmissionMode(setup.manifest) == SubmissionMode.uploadOnly.rawValue
    {
        throw AppError.badRequest(
            reason: uploadModeGradingConflictMessage)
    }
    if parsed == .browser,
        !currentManifestGraderOnlyFiles(setup.manifest).isEmpty
    {
        throw AppError.badRequest(reason: graderOnlyGradingConflictMessage)
    }
    // And for an activity that stages an opponent: the opponent lives in a
    // directory only the native worker creates, so a browser-graded match
    // would run with nobody on the other side.
    if parsed == .browser, currentManifestActivityStagesAnOpponent(setup.manifest) {
        throw AppError.badRequest(reason: activityOpponentGradingConflictMessage)
    }
    if currentManifestGradingMode(setup.manifest) != mode {
        try await mutateManifest(setup: setup, on: db) { props in
            props.gradingMode = parsed
        }
    }
    return mode
}

/// The one message both halves of the upload/browser refusal use, so the web
/// form banner and the MCP tool error stay identical.
let uploadModeGradingConflictMessage =
    "An upload-only assignment is graded by the native worker; it cannot use browser grading. "
    + "Switch the grading mode to \"worker\" first."

/// One message for every door of the grader-only/browser refusal (mode
/// switch, zip upload — and `author_script`, which words the same rule from
/// the marking direction). Browser grading streams the setup workspace into
/// the student's kernel, so a grader-only file cannot be withheld there.
let graderOnlyGradingConflictMessage =
    "This assignment marks grader-only files, which browser grading would deliver to every "
    + "student's kernel. Remove the graderOnly marks first, or keep worker grading."

/// One message for every door of the opponent/browser refusal (mode switch,
/// zip upload, and `set_activity` from the kind's direction). Only the native
/// worker stages an opponent (docs/class-activities.md), so a browser-graded
/// match would run with nobody on the other side and read as a win.
let activityOpponentGradingConflictMessage =
    "This class activity plays each submission against an opponent, which only the native "
    + "worker can stage. Keep worker grading, or choose an activity kind with no opponent."

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

/// The same question asked of a manifest's recorded `language`, for the sites
/// that hold raw manifest JSON rather than a decoded `TestProperties`. An
/// absent language is not upload-only.
func manifestRequiresUploadOnlySubmission(_ manifest: String?) -> AssignmentLanguage? {
    guard let language = manifest.flatMap(decodeManifest(fromJSON:))?.language,
        requiresUploadOnlySubmission(language)
    else { return nil }
    return language
}

/// Reads the recorded `language` of a manifest JSON string, or nil when none
/// is recorded (or the manifest can't be decoded).
func currentManifestLanguage(_ manifest: String?) -> String? {
    manifest.flatMap(decodeManifest(fromJSON:))?.language?.rawValue
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
    try await mutateManifest(setup: setup, on: db) { props in
        props.language = parsed
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
    try await mutateManifest(setup: setup, on: db) { props in
        props.languageDeclared = true
        props.language = language
        if let language, case .uploadOnly = language.editorSupport {
            props.submissionMode = .uploadOnly
            props.gradingMode = .worker
        }
    }
}

/// True when the manifest carries any generated test — a pattern-family case or
/// a notebook check. Read off the entries rather than the family/check lists
/// so a family that has produced no enabled case doesn't block a change that
/// would rewrite nothing.
func manifestHasGeneratedScripts(_ manifest: String?) -> Bool {
    manifest.flatMap(decodeManifest(fromJSON:))?.testSuites.contains(where: \.isGenerated) ?? false
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

/// Reads the `submissionMode` of a manifest JSON string, defaulting to
/// "notebook" (TestProperties' own default) when the manifest can't be
/// decoded.
func currentManifestSubmissionMode(_ manifest: String?) -> String {
    (manifest.flatMap(decodeManifest(fromJSON:))?.submissionMode ?? .notebook).rawValue
}

/// Sets the test setup's `submissionMode` to `mode` when it differs.  Returns
/// the effective mode.  Refuses `upload` while the setup is browser-graded —
/// the mirror of `setManifestGradingMode`'s guard, so the incoherent
/// combination cannot be authored from either direction.
func setManifestSubmissionMode(
    setup: APITestSetup, to mode: String, on db: any Database
) async throws -> String {
    guard let parsed = SubmissionMode(rawValue: mode) else {
        throw AppError.badRequest(reason: "Unknown submission mode \"\(mode)\".")
    }
    if parsed == .uploadOnly,
        currentManifestGradingMode(setup.manifest) == GradingMode.browser.rawValue
    {
        throw AppError.badRequest(
            reason: uploadModeGradingConflictMessage)
    }
    // The coherence rule from the other direction: an instructor cannot flip
    // an upload-only language back to the notebook workflow it does not have.
    // Asked of `editorSupport` rather than spelled `== .cpp`, which is what let
    // Racket through here.
    if parsed == .notebook,
        let language = manifestRequiresUploadOnlySubmission(setup.manifest)
    {
        throw AppError.badRequest(reason: requiresUploadOnlyMessage(language))
    }
    if currentManifestSubmissionMode(setup.manifest) != mode {
        try await mutateManifest(setup: setup, on: db) { props in
            props.submissionMode = parsed
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
    let present = currentManifestGraderOnlyFiles(setup.manifest).contains(filename)
    guard graderOnly != present else { return }  // already in the desired state
    try await mutateManifest(setup: setup, on: db) { props in
        if graderOnly {
            props.graderOnlyFiles.append(filename)
        } else {
            props.graderOnlyFiles.removeAll { $0 == filename }
        }
    }
}

/// Sets the test setup's default `timeLimitSeconds` to `seconds` when it
/// differs.  Returns the effective value.
func setManifestTimeLimitSeconds(
    setup: APITestSetup, to seconds: Int, on db: any Database
) async throws -> Int {
    if setup.decodedManifest()?.timeLimitSeconds != seconds {
        try await mutateManifest(setup: setup, on: db) { props in
            props.timeLimitSeconds = seconds
        }
    }
    return seconds
}

/// Sets (or clears) the test setup's `minimumRunnerVersion` gate, saving only
/// when it actually changes.  A blank/nil `version` clears the gate (the key is
/// omitted, matching `TestProperties.encodeIfPresent`).  A gated setup is only
/// handed to a native runner whose advertised version is `>=` this value — see
/// docs/runner-capability-profiles.md.  Returns the effective value (nil when
/// cleared).
func setManifestMinimumRunnerVersion(
    setup: APITestSetup, to version: String?, on db: any Database
) async throws -> String? {
    let normalized = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effective = (normalized?.isEmpty == false) ? normalized : nil
    guard setup.decodedManifest()?.minimumRunnerVersion != effective else { return effective }
    try await mutateManifest(setup: setup, on: db) { props in
        props.minimumRunnerVersion = effective
    }
    return effective
}

/// Turns GitHub submission on or off for the test setup
/// (docs/github-submissions.md slice 3), saving only when it changes. Off
/// omits the key, matching `TestProperties.encode`, which omits `false`.
func setManifestGitHubSubmission(setup: APITestSetup, enabled: Bool, on db: any Database) async throws {
    guard setup.decodedManifest()?.githubSubmission != enabled else { return }
    try await mutateManifest(setup: setup, on: db) { props in
        props.githubSubmission = enabled
    }
}

/// Turns commit statuses on or off (slice 6), saving only when it changes.
/// Off omits the key, matching `TestProperties.encode`.
func setManifestGitHubStatusChecks(setup: APITestSetup, enabled: Bool, on db: any Database) async throws {
    guard setup.decodedManifest()?.githubStatusChecks != enabled else { return }
    try await mutateManifest(setup: setup, on: db) { props in
        props.githubStatusChecks = enabled
    }
}

/// Reads the `activity` block of a manifest JSON string — nil when the field
/// is absent, or the manifest can't be decoded (which includes an activity
/// kind this build does not know).
func currentManifestActivity(_ manifest: String?) -> ClassActivity? {
    manifest.flatMap(decodeManifest(fromJSON:))?.activity
}

/// True when the manifest's activity stages an opponent (a bot kind with its
/// file chosen) — the predicate every browser-grading door asks, so they
/// cannot disagree about what it covers.
func currentManifestActivityStagesAnOpponent(_ manifest: String?) -> Bool {
    currentManifestActivity(manifest)?.stagesAnOpponent == true
}

/// Sets (or clears, with nil) the test setup's `activity` block, saving only
/// when it actually changes.
///
/// Callers decide the lifecycle rule (the kind is locked once a student has
/// submitted); this helper only writes.
func setManifestActivity(
    setup: APITestSetup, to activity: ClassActivity?, on db: any Database
) async throws {
    guard currentManifestActivity(setup.manifest) != activity else { return }
    try await mutateManifest(setup: setup, on: db) { props in
        props.activity = activity
    }
}
