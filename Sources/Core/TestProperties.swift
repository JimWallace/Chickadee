// Core/TestProperties.swift
//
// Replaces legacy test.properties. Stored as JSON inside the test setup
// zip uploaded by the instructor.

/// Where and how a submission is graded.
///
/// - `worker`: The submission is queued for a native runner on the server
///   (default — handles shell-script and Python test suites).
/// - `browser`: The student's browser runs tests locally via Pyodide and
///   POSTs the notebook + `TestOutcomeCollection` in one atomic call.
///   No server-side runner is involved.
///
/// Default when the field is absent from JSON: `.worker`.
public enum GradingMode: String, Codable, Sendable, Equatable {
    case browser
    case worker
}

/// Entry for a single test in the manifest.
/// `script` is the filename/path of a runnable test script in the test setup zip.
/// `name` is an optional human-readable display name shown to students. When absent,
/// the display name falls back to the script filename without its extension.
/// `dependsOn` is an optional list of prerequisites that must pass before this
/// test runs.  In the **authored** manifest (as produced by the `/suite` editor),
/// entries can be either raw script filenames or `family:<id>` tokens referring
/// to a pattern family by id.  The server expands `family:<id>` tokens into the
/// family's enabled generated filenames before persisting the manifest for the
/// runner, so the runner only ever sees concrete script names in `dependsOn`.
/// If any prerequisite did not pass, this test is auto-failed.
/// `points` is the integer weight used for grade calculation (default 1).
/// `generatedBy` is the id of the `PatternFamily` that produced this entry, or
/// nil for hand-written scripts.  Generated scripts are read-only in the
/// raw-script editor; edits and deletes flow through the family editor.
/// `generatedByCheck` is the parallel field for `NotebookCheck`-generated
/// entries.  At most one of `generatedBy` / `generatedByCheck` is non-nil
/// for any given entry (validation enforces this); both nil means a
/// hand-written script.
public struct TestSuiteEntry: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let script: String  // e.g. "01_public.py"
    public let name: String?  // optional display name shown to students
    public let dependsOn: [String]  // script names of prerequisites; empty == no deps
    public let points: Int  // grade weight; 1 = default (unweighted)
    public let generatedBy: String?  // pattern family id, nil for hand-written scripts
    public let generatedByCheck: String?  // notebook check id, nil otherwise
    public let sectionID: String?  // id into TestProperties.sections, or nil = ungrouped
    // Optional instructor hint shown as a "💡 Hint" callout when this test
    // fails (surfaced at results-display time). For generated entries the
    // hint comes from the family case / notebook check spec instead; this
    // field carries the hint for hand-written raw scripts. nil = none.
    public let hint: String?
    // Optional per-test execution time limit (seconds). When nil the entry
    // inherits the assignment-wide default `TestProperties.timeLimitSeconds`.
    // Resolution happens in each executor (the worker's NativeScriptExecutor,
    // the browser runner's JS) rather than in RunnerCore's `executeSuites`,
    // which is the wasm-pinned shared loop and still receives the assignment
    // default as the fallback timeLimit. Effective limit for a script is
    // `entry.timeLimitSeconds ?? manifest.timeLimitSeconds`. Back-compat:
    // absent in JSON decodes to nil (inherit the default).
    public let timeLimitSeconds: Int?

    public init(
        tier: TestTier, script: String, name: String? = nil,
        dependsOn: [String] = [], points: Int = 1,
        generatedBy: String? = nil,
        generatedByCheck: String? = nil,
        sectionID: String? = nil,
        hint: String? = nil,
        timeLimitSeconds: Int? = nil
    ) {
        self.tier = tier
        self.script = script
        self.name = name
        self.dependsOn = dependsOn
        self.points = points
        self.generatedBy = generatedBy
        self.generatedByCheck = generatedByCheck
        self.sectionID = sectionID
        self.hint = hint
        self.timeLimitSeconds = timeLimitSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decode(TestTier.self, forKey: .tier)
        script = try c.decode(String.self, forKey: .script)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        points = try c.decodeIfPresent(Int.self, forKey: .points) ?? 1
        generatedBy = try c.decodeIfPresent(String.self, forKey: .generatedBy)
        generatedByCheck = try c.decodeIfPresent(String.self, forKey: .generatedByCheck)
        sectionID = try c.decodeIfPresent(String.self, forKey: .sectionID)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        timeLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .timeLimitSeconds)
    }

    /// True if this entry was produced by a pattern family or a notebook
    /// check.  Raw-script-edit guards consult this so they refuse to mutate
    /// generated entries regardless of which generator produced them.
    public var isGenerated: Bool {
        generatedBy != nil || generatedByCheck != nil
    }
}

// `skippedPrerequisiteMessage(prerequisite:)` moved down into RunnerCore (the
// wasm-safe leaf shared by both runners). Reached here via `import Core`, which
// re-exports RunnerCore — so existing call sites are unchanged.

/// A named grouping of test suite entries.  Sections drive visual
/// grouping on the instructor suite editor and the student submission
/// results page, and (v0.4.100+) carry an optional list of
/// section-scoped variables that every pattern family in the section
/// can reference via the `$name` syntax.
///
/// `id` is opaque (UUID generated in the browser), so renames are free.
public struct TestSuiteSection: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Variables available to every pattern family in this section.
    /// Uses the same shape as `FamilyVariable` (name + JSON-expressible
    /// value) so the `$name` resolver, validator, and auto-compute code
    /// paths stay unchanged.  Family-level variables of the same name
    /// shadow section-level ones in the generated test.
    public let variables: [FamilyVariable]

    /// Slice 4 of #461 — per-student expressions in section scope.
    /// Evaluated per-student at notebook first-open alongside global
    /// expressions; results substitute into `{{name}}` placeholders.
    /// Like `globalExpressions`, a section expression is never inlined
    /// into a raw test script, but it MAY back a pattern-family
    /// per-student reference (`$name` arg / `expectedVarRef`), whose
    /// value is delivered to grading at dispatch time via
    /// `Job.personalizedInputs` / the browser seed endpoint.
    public let expressions: [PersonalizationExpression]

    public init(
        id: String, name: String,
        variables: [FamilyVariable] = [],
        expressions: [PersonalizationExpression] = []
    ) {
        self.id = id
        self.name = name
        self.variables = variables
        self.expressions = expressions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        variables = try c.decodeIfPresent([FamilyVariable].self, forKey: .variables) ?? []
        expressions = try c.decodeIfPresent([PersonalizationExpression].self, forKey: .expressions) ?? []
    }
}

/// Optional Makefile step to run before tests.
public struct MakefileConfig: Codable, Equatable, Sendable {
    public let target: String?  // nil means bare `make` with no target
}

/// Slice 2 of #461 — a named, per-student-evaluated Python expression
/// at assignment scope.  The expression is evaluated server-side at
/// notebook first-open with `seed` bound to the per-(student, assignment)
/// random integer.  The result substitutes into starter-notebook
/// `{{name}}` placeholders alongside literal `globalVariables`.
///
/// Distinct from `globalVariables` to keep the schema homogeneous —
/// each type holds the shape it actually uses (literal value vs Python
/// source).  Names share the same Python-identifier namespace as
/// `globalVariables` and `sections[].variables`; validators enforce no
/// overlap.
public struct PersonalizationExpression: Codable, Equatable, Sendable {
    public let name: String
    public let expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

/// Top-level manifest describing how to build and test a submission.
public struct TestProperties: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let gradingMode: GradingMode
    public let requiredFiles: [String]
    public let testSuites: [TestSuiteEntry]
    public let timeLimitSeconds: Int
    public let makefile: MakefileConfig?
    /// Filename of the starter/template notebook bundled in the test setup zip
    /// (e.g. "assignment.ipynb").  The runner removes this file before executing
    /// tests so grading scripts don't confuse it with the student's submission.
    /// Nil when the assignment has no notebook template.
    public let starterNotebook: String?
    /// The unified list of instructor-authored test-item specs — pattern
    /// families and notebook checks both — that expand into some of the
    /// entries in `testSuites`.  This is the single source of truth; the
    /// `patternFamilies` / `notebookChecks` accessors below are derived
    /// views kept for the many existing read sites.  The runner ignores
    /// this field entirely (families and checks are a save-time authoring
    /// concern; by the time the zip reaches the runner every generated
    /// `.py` is an ordinary test script), and `runnerSanitized()` empties
    /// it so older runners never decode a `PatternKind` / `NotebookCheckKind`
    /// case they don't know.
    ///
    /// Legacy manifests (pre-`testItems`) carry separate `patternFamilies`
    /// and `notebookChecks` arrays; `init(from:)` migrates them into
    /// `testItems` on read, and `encode(to:)` mirrors both legacy keys back
    /// out (derived from `testItems`) so cross-version readers stay happy.
    public let testItems: [TestItem]

    /// Pattern-family specs, derived from `testItems`.  Order follows the
    /// item list.  A save-time authoring concern only.
    public var patternFamilies: [PatternFamily] { testItems.compactMap(\.family) }
    /// Notebook-check specs, derived from `testItems`.  Order follows the
    /// item list.  A save-time authoring concern only.
    public var notebookChecks: [NotebookCheck] { testItems.compactMap(\.check) }
    /// Ordered list of sections that group `testSuites` for display only.
    /// Empty = "no grouping"; the student and instructor UIs render
    /// identically to the pre-sections layout.  Entries in `testSuites`
    /// reference a section by `sectionID`; the run order is still the
    /// order of `testSuites` itself (the server is responsible for
    /// keeping items with the same `sectionID` in a contiguous block).
    public let sections: [TestSuiteSection]

    /// Assignment-scope variables, available to every pattern family,
    /// every notebook check, every raw test script, and every notebook
    /// `{{name}}` placeholder in this assignment.  Static values; same
    /// shape as section variables (`FamilyVariable` = name + JSON-able
    /// value).
    ///
    /// Slice 1 (v0.4.x): values are inlined at save time — prepended
    /// to Python test scripts, resolved in notebook-check expected
    /// values, and substituted into the student starter notebook at
    /// first-open.  The runner sees test scripts and check expecteds
    /// with values already baked in; runners don't need to know about
    /// this field, but it's kept in the runner payload (harmless,
    /// `FamilyVariable` is already a known type) for parity with
    /// `sections.variables`.
    public let globalVariables: [FamilyVariable]

    /// Slice 2 of #461 — assignment-scope Python expressions evaluated
    /// per-student at notebook first-open with `seed` bound.  Their
    /// values substitute into starter-notebook `{{name}}` placeholders
    /// alongside literal `globalVariables`.
    ///
    /// Expression results are NOT inlined into raw test scripts (those use
    /// the v0.4.156 env-var seed contract for any per-student logic) and are
    /// NOT substituted into them at save time.  They ARE, however, available
    /// to pattern-family per-student references: a case's `$name` arg or
    /// `expectedVarRef` may point at an expression row, and the resolved
    /// value is delivered to grading at dispatch time via
    /// `Job.personalizedInputs` / the browser seed endpoint (see
    /// `docs/personalization-pattern-families.md`).  Names cannot clash with
    /// any `globalVariables`, `sections[].variables`, or the reserved name
    /// `seed`.
    public let globalExpressions: [PersonalizationExpression]

    /// Per-student dataset specs (Phase 1 — see docs/datasets.md).  Each entry
    /// marks one bundled support file as a per-student dataset: the server
    /// materializes a deterministic slice from the assignment seed (see
    /// `DatasetMaterializer`) and delivers the bytes to grading + the editor
    /// under the same filename.  A save-time authoring concern — the runner
    /// receives the already-materialized file, never the spec — so
    /// `runnerSanitized()` strips it via the memberwise default (like
    /// `patternFamilies` / `globalExpressions`).
    public let datasets: [DatasetSpec]

    /// Filenames the instructor has designated as **grader-only** (option B —
    /// see docs/datasets.md): bundled in the test setup so the native worker's
    /// grading scripts can read them, but withheld from every student-facing
    /// path (editor symlinks, browser-runner download, student support-file
    /// download).  This is the reserved holdout / secret test set.  A
    /// grader-only entry is otherwise an ordinary support file; this list just
    /// flags it as student-hidden.  Server-side only — the worker receives the
    /// file via the test-setup zip and needs no marker — so `runnerSanitized()`
    /// strips it via the memberwise default (like `datasets`).
    public let graderOnlyFiles: [String]

    /// The grader-only filenames as a set, for unioning into the student-facing
    /// `reservedNames` filters at each delivery point.
    public var graderOnlyFileSet: Set<String> { Set(graderOnlyFiles) }

    /// True when the manifest declares any per-student `=` expression, global
    /// or section-scoped.  Expressions are the only personalization inputs
    /// that need a per-(student, assignment) seed to resolve — use this to
    /// decide whether a seed must be looked up.  Ask `hasPersonalization`
    /// instead when the question is "is there anything to substitute at all".
    public var hasExpressions: Bool {
        !globalExpressions.isEmpty || sections.contains { !$0.expressions.isEmpty }
    }

    /// True when the manifest declares anything personalization substitutes —
    /// literal variables or per-student expressions, global or section-scoped.
    /// Strictly broader than `hasExpressions`: a literal-only assignment still
    /// substitutes `{{name}}` placeholders, it just needs no seed.
    public var hasPersonalization: Bool {
        hasExpressions || !globalVariables.isEmpty || sections.contains { !$0.variables.isEmpty }
    }

    /// Instructor-authored achievements / goals / awards for this assignment —
    /// the generalized form of the hardcoded badge + class-achievement system.
    /// Server-evaluated and display-only; `runnerSanitized()` strips them so a
    /// runner never decodes an achievement shape it doesn't know (same rationale
    /// as `patternFamilies` / `notebookChecks`).
    public let achievements: [Achievement]

    /// IDs of built-in awards (`BuiltInAchievements`) the instructor has disabled
    /// for this assignment.  Empty = all built-ins active (the default).  The
    /// award + display paths skip any id listed here.  Stripped from the
    /// runner-facing manifest (awards are server-side) via the memberwise default.
    public let disabledBuiltInAwardIDs: [String]
    /// True once the instructor has saved the unified Achievements table.  Until
    /// then the editor merges the built-in defaults in for display; after, the
    /// manifest's `achievements` is authoritative (so a removed built-in stays
    /// removed).  Stripped from the runner manifest via the memberwise default.
    public let builtInAchievementsSeeded: Bool

    /// The language this assignment is authored and graded in.
    ///
    /// Recorded explicitly — for Python as well as R — so the answer is stated
    /// rather than re-derived. Sniffing cannot stand on its own: a suite made
    /// up only of pattern families has no `.R` script to find, so an R
    /// assignment would silently fall back to Python and start emitting `.py`
    /// cases. "We inferred Python" and "this is a Python assignment" are also
    /// genuinely different states, and only one of them is safe to act on.
    ///
    /// Nil means "written before the language was recorded" — every manifest
    /// on disk today. `AssignmentLanguage.resolve(manifest:)` falls back to
    /// sniffing for those, so they keep behaving exactly as before until their
    /// next save stamps a value.
    public let language: AssignmentLanguage?

    /// Optional minimum `chickadee-runner` version required to grade this
    /// assignment on the native worker path.  When set, the server only hands a
    /// submission for this setup to a runner whose advertised
    /// `ChickadeeVersion.current` is `>=` this value; otherwise the job stays
    /// `pending` until a new-enough runner polls.  Use it for a suite that
    /// depends on behaviour only present in a newer runner build.
    ///
    /// A plain semver string (e.g. `"0.5.0"`), parsed by the server's
    /// `VersionComparator`.  `nil` — the default, and every manifest written
    /// before this field existed — means no gate, and the enclosing manifest is
    /// then byte-for-byte unchanged.  Purely a server-side dispatch gate: the
    /// runner never needs it, so `runnerSanitized()` strips it via the memberwise
    /// default (like `datasets` / `graderOnlyFiles`).  Does not apply to browser
    /// grading (no runner version there); it only bites the worker path.
    public let minimumRunnerVersion: String?

    public init(
        schemaVersion: Int = 1,
        gradingMode: GradingMode = .worker,
        requiredFiles: [String] = [],
        testSuites: [TestSuiteEntry] = [],
        timeLimitSeconds: Int = 10,
        makefile: MakefileConfig? = nil,
        starterNotebook: String? = nil,
        language: AssignmentLanguage? = nil,
        minimumRunnerVersion: String? = nil,
        patternFamilies: [PatternFamily] = [],
        notebookChecks: [NotebookCheck] = [],
        sections: [TestSuiteSection] = [],
        globalVariables: [FamilyVariable] = [],
        globalExpressions: [PersonalizationExpression] = [],
        datasets: [DatasetSpec] = [],
        graderOnlyFiles: [String] = [],
        achievements: [Achievement] = [],
        disabledBuiltInAwardIDs: [String] = [],
        builtInAchievementsSeeded: Bool = false,
        testItems: [TestItem]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.gradingMode = gradingMode
        self.requiredFiles = requiredFiles
        self.testSuites = testSuites
        self.timeLimitSeconds = timeLimitSeconds
        self.makefile = makefile
        self.starterNotebook = starterNotebook
        self.language = language
        self.minimumRunnerVersion = minimumRunnerVersion
        // `testItems` wins when supplied; otherwise synthesize it from the
        // legacy `patternFamilies` / `notebookChecks` arguments (families
        // first, then checks) so every existing call site keeps working.
        self.testItems =
            testItems
            ?? (patternFamilies.map(TestItem.family)
                + notebookChecks.map(TestItem.check))
        self.sections = sections
        self.globalVariables = globalVariables
        self.globalExpressions = globalExpressions
        self.datasets = datasets
        self.graderOnlyFiles = graderOnlyFiles
        self.achievements = achievements
        self.disabledBuiltInAwardIDs = disabledBuiltInAwardIDs
        self.builtInAchievementsSeeded = builtInAchievementsSeeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        gradingMode = try c.decodeIfPresent(GradingMode.self, forKey: .gradingMode) ?? .worker
        requiredFiles = try c.decodeIfPresent([String].self, forKey: .requiredFiles) ?? []
        testSuites = try c.decodeIfPresent([TestSuiteEntry].self, forKey: .testSuites) ?? []
        timeLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .timeLimitSeconds) ?? 10
        makefile = try c.decodeIfPresent(MakefileConfig.self, forKey: .makefile)
        starterNotebook = try c.decodeIfPresent(String.self, forKey: .starterNotebook)
        // Absent on every manifest written before the language became
        // first-class; nil falls back to sniffing the suite.
        language = try c.decodeIfPresent(AssignmentLanguage.self, forKey: .language)
        minimumRunnerVersion = try c.decodeIfPresent(String.self, forKey: .minimumRunnerVersion)
        // `testItems` is the canonical unified list when present.  A legacy
        // manifest carries the separate `patternFamilies` / `notebookChecks`
        // arrays instead — migrate them on read.  (An explicitly-empty
        // `testItems` is treated the same as absent so an old + new pair
        // that disagree never silently drops specs.)
        let decodedItems = try c.decodeIfPresent([TestItem].self, forKey: .testItems) ?? []
        if decodedItems.isEmpty {
            let fams = try c.decodeIfPresent([PatternFamily].self, forKey: .patternFamilies) ?? []
            let checks = try c.decodeIfPresent([NotebookCheck].self, forKey: .notebookChecks) ?? []
            testItems = fams.map(TestItem.family) + checks.map(TestItem.check)
        } else {
            testItems = decodedItems
        }
        sections = try c.decodeIfPresent([TestSuiteSection].self, forKey: .sections) ?? []
        globalVariables = try c.decodeIfPresent([FamilyVariable].self, forKey: .globalVariables) ?? []
        globalExpressions =
            try c.decodeIfPresent(
                [PersonalizationExpression].self,
                forKey: .globalExpressions) ?? []
        datasets = try c.decodeIfPresent([DatasetSpec].self, forKey: .datasets) ?? []
        graderOnlyFiles = try c.decodeIfPresent([String].self, forKey: .graderOnlyFiles) ?? []
        achievements = try c.decodeIfPresent([Achievement].self, forKey: .achievements) ?? []
        disabledBuiltInAwardIDs =
            try c.decodeIfPresent([String].self, forKey: .disabledBuiltInAwardIDs) ?? []
        builtInAchievementsSeeded =
            try c.decodeIfPresent(Bool.self, forKey: .builtInAchievementsSeeded) ?? false
    }

    // `patternFamilies` / `notebookChecks` are computed (derived from
    // `testItems`) so they're absent from the synthesized `CodingKeys`;
    // declare the keys explicitly so `init(from:)` can still read the
    // legacy arrays and `encode(to:)` can mirror them back out.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gradingMode
        case requiredFiles
        case testSuites
        case timeLimitSeconds
        case makefile
        case starterNotebook
        case language
        case minimumRunnerVersion
        case testItems
        case patternFamilies
        case notebookChecks
        case sections
        case globalVariables
        case globalExpressions
        case datasets
        case graderOnlyFiles
        case achievements
        case disabledBuiltInAwardIDs
        case builtInAchievementsSeeded
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(gradingMode, forKey: .gradingMode)
        try c.encode(requiredFiles, forKey: .requiredFiles)
        try c.encode(testSuites, forKey: .testSuites)
        try c.encode(timeLimitSeconds, forKey: .timeLimitSeconds)
        try c.encodeIfPresent(makefile, forKey: .makefile)
        try c.encodeIfPresent(starterNotebook, forKey: .starterNotebook)
        // encodeIfPresent, not encode: an assignment with no recorded language
        // must produce the exact bytes it always has.
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(minimumRunnerVersion, forKey: .minimumRunnerVersion)
        try c.encode(testItems, forKey: .testItems)
        // Mirror the legacy arrays (derived from `testItems`, so they can
        // never drift) for cross-version readers that predate `testItems`.
        // DEPRECATED write-side mirroring — remove in the v0.7.0 cleanup,
        // once no supported reader (runner binary or course-bundle importer)
        // predates `testItems`.  The read-side migration in `init(from:)`
        // stays forever: old manifests on disk / in exported bundles carry
        // only the legacy arrays and must keep decoding.
        try c.encode(patternFamilies, forKey: .patternFamilies)
        try c.encode(notebookChecks, forKey: .notebookChecks)
        try c.encode(sections, forKey: .sections)
        try c.encode(globalVariables, forKey: .globalVariables)
        try c.encode(globalExpressions, forKey: .globalExpressions)
        try c.encode(datasets, forKey: .datasets)
        try c.encode(graderOnlyFiles, forKey: .graderOnlyFiles)
        try c.encode(achievements, forKey: .achievements)
        try c.encode(disabledBuiltInAwardIDs, forKey: .disabledBuiltInAwardIDs)
        try c.encode(builtInAchievementsSeeded, forKey: .builtInAchievementsSeeded)
    }

    /// Manifest view shipped to runners.  Pattern families and notebook
    /// checks are save-time authoring concerns — by the time the zip
    /// reaches the runner every generated `.py` is already an ordinary
    /// test script — so they are stripped before encode (which empties
    /// the derived `testItems` list as well).  Keeping them in the payload
    /// would force every runner binary to know every `PatternKind` /
    /// `NotebookCheckKind` case the server ever introduces (a new raw value
    /// crashes the enum decoder), defeating rolling deployments.
    public func runnerSanitized() -> TestProperties {
        TestProperties(
            schemaVersion: schemaVersion,
            gradingMode: gradingMode,
            requiredFiles: requiredFiles,
            testSuites: testSuites,
            timeLimitSeconds: timeLimitSeconds,
            makefile: makefile,
            starterNotebook: starterNotebook,
            // Kept: the runner reads the language off `Job.language`, but a
            // manifest that silently lost it here would resolve differently on
            // any path that re-sniffs from the runner-facing copy.
            language: language,
            patternFamilies: [],
            notebookChecks: [],
            // Expressions are a server-side authoring concern — both global
            // AND section scope.  Their source is evaluated server-side per
            // student; only the resolved values travel to grading (worker via
            // `Job.personalizedInputs`, browser via the seed endpoint), and
            // the runner reads neither `globalExpressions` nor
            // `sections[].expressions`.  Strip every `PersonalizationExpression`
            // from the runner-facing manifest so reference-solution source
            // (e.g. `= solution.countAdults(...)`) never ships in the Job
            // payload.  Section *variables* (literals) are kept for parity
            // with `globalVariables`.
            sections: sections.map { section in
                TestSuiteSection(
                    id: section.id, name: section.name,
                    variables: section.variables, expressions: [])
            },
            globalVariables: globalVariables,
            globalExpressions: [],
            // `datasets` and `graderOnlyFiles` are dropped via the memberwise
            // default: the runner receives the materialized per-student file
            // (delivered with the job, like `_ck_inputs.py`) and the grader-only
            // file (via the test-setup zip) directly — never the specs/markers.
            achievements: []
        )
    }
}
