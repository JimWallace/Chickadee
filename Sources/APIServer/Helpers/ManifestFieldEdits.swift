// APIServer/Helpers/ManifestFieldEdits.swift
//
// Single-field manifest edits shared across surfaces (#1121): the MCP tools
// (`set_grading_mode`, `set_time_limit`, `author_script`,
// `set_assignment_course_section`) and the web section-adoption path
// (`CourseAdminRoutes+Sections`) all change exactly one field of
// `test_setups.manifest`.  Each helper is a `mutateManifest` closure
// (below) over the decoded `TestProperties`, so the decode →
// mutate → stable-encode → save pattern lives once, and so does the rule
// that a no-op edit does not bump the row: the stable encoder makes "the
// field changed" the same question as "the bytes changed", so `mutateManifest`
// compares the bytes and a helper does not compare the field.  A manifest
// that does not decode throws — that indicates a corrupted setup, not a user
// error.

import Core
import Fluent
import Foundation
import SQLKit

// MARK: - Manifest mutation

/// Decodes the test setup's manifest, runs the caller's mutation on the
/// `TestProperties` value, encodes it with the stable encoder and saves.
/// Throws if the manifest does not decode — that indicates a corrupted
/// setup, not a user error.
///
/// Every single-field edit goes through here (the helpers below,
/// the suite-section CRUD, the MCP tools), so there is one writer of a
/// stored manifest.  It used to edit a `[String: Any]` dictionary so that a
/// key the server did not model would survive an edit; nothing ever read
/// such a key, and the suite rebuild (`makeWorkerManifestJSON`) dropped it
/// anyway.  A typed edit cannot misspell a key or drop a field it did not
/// think to carry.
///
/// The save is conditional on the manifest the edit read (#2019). Two staff
/// edits on one assignment at once, say `PUT /achievements` and `PUT /suite`,
/// used to be last-writer-wins: the first edit was lost with no error. Now
/// the second writer finds the manifest changed, re-reads it, and applies its
/// edit again on top. `mutate` can run more than once, so it must only change
/// `props`. After `manifestWriteAttempts` conflicts the edit is refused, so
/// the author can retry.
func mutateManifest(
    setup: APITestSetup,
    on db: Database,
    _ mutate: (inout TestProperties) throws -> Void
) async throws {
    try await mutateManifestJSON(setup: setup, on: db) { manifest in
        guard var props = decodeManifest(fromJSON: manifest) else {
            throw WebAssignmentError.internalFailure(reason: "Test setup manifest could not be decoded.")
        }
        try mutate(&props)
        return try encodeManifest(props)
    }
}

/// `mutateManifest` for an edit written against the manifest JSON, such as
/// `updateManifestAddingScript`. `transform` returns the new manifest, or nil
/// to write nothing. It must be a pure function of the manifest it is given,
/// because a lost race applies it again to the newer manifest (#2485).
func mutateManifestJSON(
    setup: APITestSetup,
    on db: Database,
    _ transform: (String) throws -> String?
) async throws {
    for _ in 0..<manifestWriteAttempts {
        guard let written = try transform(setup.manifest) else { return }
        // A no-op edit writes nothing, so nothing keyed on the bytes (a
        // version snapshot, the runner's setup cache) sees a change.
        if written == setup.manifest { return }
        if try await replaceManifest(of: setup, with: written, on: db) { return }
        // Another edit saved first. Start again from what it saved.
        guard let current = try await APITestSetup.find(setup.id, on: db) else {
            throw AppError.notFound(resource: "Assignment")
        }
        try setup.$manifest.output(from: ManifestRow(manifest: current.manifest))
    }
    throw AppError.conflict(reason: concurrentManifestEditMessage)
}

/// How many times `mutateManifest` re-applies an edit that lost a race.
private let manifestWriteAttempts = 3

/// The refusal for an edit that lost a race and cannot simply be applied again.
let concurrentManifestEditMessage =
    "Another edit to this assignment saved at the same time. Reload and try again."

/// Writes `manifest` over the manifest that `setup` was read with, or throws a
/// conflict when another edit saved first (#2485).
///
/// For a write whose new manifest was built from slow work on the old one,
/// such as `applyPatternFamilies`, which renders generated tests from it.
/// `mutateManifest` re-applies a lost edit to the newer manifest, but this
/// write cannot: its rendered files were based on a manifest that is no longer
/// current. Before this, it saved without a condition, and a concurrent edit
/// (achievements, datasets) was lost with no error.
///
/// Only the manifest is written. A caller that also changed another field of
/// `setup` must save that field itself.
func saveManifestReplacing(_ setup: APITestSetup, with manifest: String, on db: Database) async throws {
    guard try await replaceManifest(of: setup, with: manifest, on: db) else {
        throw AppError.conflict(reason: concurrentManifestEditMessage)
    }
}

/// Writes `manifest` only if the stored manifest is still the one `setup`
/// holds, in one `UPDATE … WHERE manifest = … RETURNING` statement, which is
/// atomic on SQLite and Postgres (the `SingleUseRecord` pattern). Returns
/// false when another writer changed it first. On success the model takes the
/// new value as saved, not as a pending change, so a later `save()` of the
/// same model does not write the manifest again without this check.
private func replaceManifest(
    of setup: APITestSetup, with manifest: String, on db: Database
) async throws -> Bool {
    guard let sql = db as? SQLDatabase else {
        setup.manifest = manifest
        try await setup.save(on: db)
        return true
    }
    let id = try setup.requireID()
    let rows = try await sql.raw(
        """
        UPDATE \(unsafeRaw: APITestSetup.schema) SET manifest = \(bind: manifest) \
        WHERE id = \(bind: id) AND manifest = \(bind: setup.manifest) RETURNING id
        """
    ).all()
    guard !rows.isEmpty else { return false }
    try setup.$manifest.output(from: ManifestRow(manifest: manifest))
    return true
}

/// A database row holding only the manifest, so a model can take a value the
/// database already has without marking the field as changed.
private struct ManifestRow: DatabaseOutput {
    let manifest: String

    var description: String { "manifest" }

    func schema(_ schema: String) -> any DatabaseOutput { self }

    func contains(_ key: FieldKey) -> Bool { key == "manifest" }

    func decodeNil(_ key: FieldKey) throws -> Bool { false }

    func decode<T: Decodable>(_ key: FieldKey, as type: T.Type) throws -> T {
        guard let value = manifest as? T else {
            throw DecodingError.typeMismatch(
                T.self, .init(codingPath: [], debugDescription: "The manifest is a String."))
        }
        return value
    }
}

/// Reads the `gradingMode` of a manifest JSON string, defaulting to "worker"
/// (TestProperties' own default) when the manifest can't be decoded — so every
/// tool reports the same effective mode `get_assignment` does.
func currentManifestGradingMode(_ manifest: String?) -> String {
    (manifest.flatMap(decodeManifest(fromJSON:))?.gradingMode ?? .worker).rawValue
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
    if let violation = ManifestCoherence.violation(introducedBy: { $0.gradingMode = parsed }, in: setup.manifest) {
        throw AppError.badRequest(reason: violation)
    }
    try await mutateManifest(setup: setup, on: db) { props in
        props.gradingMode = parsed
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

/// Removes the manifest marks that name `filename`: its grader-only mark and
/// its dataset spec. Returns true when one was removed.
///
/// The web delete and MCP `delete_support_file` both call it after they remove
/// the file (#2487). A mark left behind names a file that is gone: a dataset
/// spec then names a missing file, a grader-only mark blocks browser grading
/// through `ManifestCoherence`, and a later file that reuses the name inherits
/// both.
@discardableResult
func clearFileMarks(_ filename: String, in props: inout TestProperties) -> Bool {
    let before = (props.graderOnlyFiles.count, props.datasets.count)
    props.graderOnlyFiles.removeAll { $0 == filename }
    props.datasets.removeAll { $0.file == filename }
    return before != (props.graderOnlyFiles.count, props.datasets.count)
}

/// Reads the recorded `language` of a manifest JSON string, or nil when none
/// is recorded (or the manifest can't be decoded).
func currentManifestLanguage(_ manifest: String?) -> String? {
    manifest.flatMap(decodeManifest(fromJSON:))?.language?.rawValue
}

/// Changes the language an existing assignment declares. The web Language
/// select and MCP `set_assignment_language` both call it, so the two doors
/// apply one rule (#2486).
///
/// The rule is the declaration rule (`applyLanguageDeclaration`): nil declares
/// "none", and an upload-only language also sets upload-only submission and
/// worker grading.
///
/// It refuses a change once generated tests exist. A language change rewrites
/// every generated filename (the extension is part of the name), and only the
/// pattern-family application path can re-render them and remove the old
/// ones. Declaring the current language again is not a change, so it is never
/// refused. The check runs inside the conditional write, so it reads the same
/// manifest that the write replaces.
func changeDeclaredLanguage(
    setup: APITestSetup, to language: AssignmentLanguage?, on db: any Database
) async throws {
    try await mutateManifest(setup: setup, on: db) { props in
        if props.language != language, props.testSuites.contains(where: \.isGenerated) {
            throw AppError.badRequest(reason: languageChangeAfterGenerationMessage)
        }
        applyLanguageDeclaration(language, to: &props)
    }
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
/// This is the declaration at creation. `changeDeclaredLanguage` is the edit
/// of an assignment that already has content; it applies the same rule and
/// adds the generated-tests guard. The rule:
///
/// 1. It records `languageDeclared`, so a nil language afterwards means "the
///    author says there is none" rather than "nobody has been asked".
/// 2. An upload-only language sets `submissionMode` AND `gradingMode` too,
///    because the language implies both. A brand-new assignment is in notebook
///    mode, so a rule that refused an upload-only language there would leave
///    C++ uncreatable. It also collapses the old three-step authoring dance
///    (grading mode, then submission mode, then language) into one answer.
///    Until #2486 the MCP edit refused instead of switching; now both edit
///    doors switch too.
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
        applyLanguageDeclaration(language, to: &props)
    }
}

/// The declaration rule that `declareManifestLanguage` documents, shared with
/// `changeDeclaredLanguage`.
func applyLanguageDeclaration(_ language: AssignmentLanguage?, to props: inout TestProperties) {
    props.languageDeclared = true
    props.language = language
    if let language, requiresUploadOnlySubmission(language) {
        props.submissionMode = .uploadOnly
        props.gradingMode = .worker
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
    if let violation = ManifestCoherence.violation(introducedBy: { $0.submissionMode = parsed }, in: setup.manifest) {
        throw AppError.badRequest(reason: violation)
    }
    try await mutateManifest(setup: setup, on: db) { props in
        props.submissionMode = parsed
    }
    return mode
}

/// Adds or removes `filename` in the manifest's `graderOnlyFiles` list.  A
/// grader-only file is bundled for the worker but withheld from every
/// student-facing path — see docs/datasets.md.
func setManifestGraderOnly(
    setup: APITestSetup, filename: String, graderOnly: Bool, on db: any Database
) async throws {
    try await mutateManifest(setup: setup, on: db) { props in
        if graderOnly {
            if !props.graderOnlyFiles.contains(filename) { props.graderOnlyFiles.append(filename) }
        } else {
            props.graderOnlyFiles.removeAll { $0 == filename }
        }
    }
}

/// Sets the test setup's default `timeLimitSeconds` to `seconds`.  Returns the
/// effective value.
func setManifestTimeLimitSeconds(
    setup: APITestSetup, to seconds: Int, on db: any Database
) async throws -> Int {
    try await mutateManifest(setup: setup, on: db) { props in
        props.timeLimitSeconds = seconds
    }
    return seconds
}

/// Sets (or clears) the test setup's `minimumRunnerVersion` gate.  A
/// blank/nil `version` clears the gate (the key is
/// omitted, matching `TestProperties.encodeIfPresent`).  A gated setup is only
/// handed to a native runner whose advertised version is `>=` this value — see
/// docs/runner-capability-profiles.md.  Returns the effective value (nil when
/// cleared).
func setManifestMinimumRunnerVersion(
    setup: APITestSetup, to version: String?, on db: any Database
) async throws -> String? {
    let normalized = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effective = (normalized?.isEmpty == false) ? normalized : nil
    try await mutateManifest(setup: setup, on: db) { props in
        props.minimumRunnerVersion = effective
    }
    return effective
}

/// Turns GitHub submission on or off for the test setup
/// (docs/github-submissions.md slice 3). Off omits the key, matching
/// `TestProperties.encode`, which omits `false`.
func setManifestGitHubSubmission(setup: APITestSetup, enabled: Bool, on db: any Database) async throws {
    try await mutateManifest(setup: setup, on: db) { props in
        props.githubSubmission = enabled
    }
}

/// Turns commit statuses on or off (slice 6). Off omits the key, matching
/// `TestProperties.encode`.
func setManifestGitHubStatusChecks(setup: APITestSetup, enabled: Bool, on db: any Database) async throws {
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

/// Sets (or clears, with nil) the test setup's `activity` block.
///
/// Callers decide the lifecycle rule (the kind is locked once a student has
/// submitted); this helper only writes.
func setManifestActivity(
    setup: APITestSetup, to activity: ClassActivity?, on db: any Database
) async throws {
    try await mutateManifest(setup: setup, on: db) { props in
        props.activity = activity
    }
}
