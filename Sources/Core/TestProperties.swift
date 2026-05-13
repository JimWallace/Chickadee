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
    public let script: String       // e.g. "01_public.py"
    public let name: String?        // optional display name shown to students
    public let dependsOn: [String]  // script names of prerequisites; empty == no deps
    public let points: Int          // grade weight; 1 = default (unweighted)
    public let generatedBy: String? // pattern family id, nil for hand-written scripts
    public let generatedByCheck: String? // notebook check id, nil otherwise
    public let sectionID: String?   // id into TestProperties.sections, or nil = ungrouped

    public init(tier: TestTier, script: String, name: String? = nil,
                dependsOn: [String] = [], points: Int = 1,
                generatedBy: String? = nil,
                generatedByCheck: String? = nil,
                sectionID: String? = nil) {
        self.tier             = tier
        self.script           = script
        self.name             = name
        self.dependsOn        = dependsOn
        self.points           = points
        self.generatedBy      = generatedBy
        self.generatedByCheck = generatedByCheck
        self.sectionID        = sectionID
    }

    public init(from decoder: Decoder) throws {
        let c            = try decoder.container(keyedBy: CodingKeys.self)
        tier             = try c.decode(TestTier.self,    forKey: .tier)
        script           = try c.decode(String.self,      forKey: .script)
        name             = try c.decodeIfPresent(String.self,   forKey: .name)
        dependsOn        = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        points           = try c.decodeIfPresent(Int.self, forKey: .points) ?? 1
        generatedBy      = try c.decodeIfPresent(String.self, forKey: .generatedBy)
        generatedByCheck = try c.decodeIfPresent(String.self, forKey: .generatedByCheck)
        sectionID        = try c.decodeIfPresent(String.self, forKey: .sectionID)
    }

    /// True if this entry was produced by a pattern family or a notebook
    /// check.  Raw-script-edit guards consult this so they refuse to mutate
    /// generated entries regardless of which generator produced them.
    public var isGenerated: Bool {
        generatedBy != nil || generatedByCheck != nil
    }
}

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

    public init(id: String, name: String, variables: [FamilyVariable] = []) {
        self.id        = id
        self.name      = name
        self.variables = variables
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(String.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        variables = try c.decodeIfPresent([FamilyVariable].self, forKey: .variables) ?? []
    }
}

/// Optional Makefile step to run before tests.
public struct MakefileConfig: Codable, Equatable, Sendable {
    public let target: String?     // nil means bare `make` with no target
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
    /// Pattern families whose expansion produced some of the entries in
    /// `testSuites`.  The runner ignores this field entirely — families are
    /// a save-time authoring concern; by the time the zip reaches the runner
    /// every generated `.py` is an ordinary test script.
    public let patternFamilies: [PatternFamily]
    /// Notebook checks whose expansion produced some of the entries in
    /// `testSuites`.  Same save-time-only model as `patternFamilies`:
    /// stripped from the runner-facing manifest by `runnerSanitized()`
    /// so older runners never see new `NotebookCheckKind` cases.
    public let notebookChecks: [NotebookCheck]
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
    /// Slice 2 scope: notebooks only.  Expression results are NOT
    /// inlined into raw test scripts (those use the v0.4.156 env-var
    /// seed contract for any per-student logic) and are NOT used for
    /// pattern-family `$name` references (case args want save-time
    /// literals).  Names cannot clash with any `globalVariables`,
    /// `sections[].variables`, or the reserved name `seed`.
    public let globalExpressions: [PersonalizationExpression]

    public init(schemaVersion: Int = 1,
                gradingMode: GradingMode = .worker,
                requiredFiles: [String] = [],
                testSuites: [TestSuiteEntry] = [],
                timeLimitSeconds: Int = 10,
                makefile: MakefileConfig? = nil,
                starterNotebook: String? = nil,
                patternFamilies: [PatternFamily] = [],
                notebookChecks: [NotebookCheck] = [],
                sections: [TestSuiteSection] = [],
                globalVariables: [FamilyVariable] = [],
                globalExpressions: [PersonalizationExpression] = []) {
        self.schemaVersion    = schemaVersion
        self.gradingMode      = gradingMode
        self.requiredFiles    = requiredFiles
        self.testSuites       = testSuites
        self.timeLimitSeconds = timeLimitSeconds
        self.makefile         = makefile
        self.starterNotebook  = starterNotebook
        self.patternFamilies  = patternFamilies
        self.notebookChecks   = notebookChecks
        self.sections         = sections
        self.globalVariables  = globalVariables
        self.globalExpressions = globalExpressions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion    = try c.decode(Int.self,                       forKey: .schemaVersion)
        gradingMode      = try c.decodeIfPresent(GradingMode.self,      forKey: .gradingMode)      ?? .worker
        requiredFiles    = try c.decodeIfPresent([String].self,         forKey: .requiredFiles)    ?? []
        testSuites       = try c.decodeIfPresent([TestSuiteEntry].self, forKey: .testSuites)       ?? []
        timeLimitSeconds = try c.decodeIfPresent(Int.self,              forKey: .timeLimitSeconds) ?? 10
        makefile         = try c.decodeIfPresent(MakefileConfig.self,   forKey: .makefile)
        starterNotebook  = try c.decodeIfPresent(String.self,           forKey: .starterNotebook)
        patternFamilies  = try c.decodeIfPresent([PatternFamily].self,  forKey: .patternFamilies)  ?? []
        notebookChecks   = try c.decodeIfPresent([NotebookCheck].self,  forKey: .notebookChecks)   ?? []
        sections         = try c.decodeIfPresent([TestSuiteSection].self, forKey: .sections)       ?? []
        globalVariables  = try c.decodeIfPresent([FamilyVariable].self, forKey: .globalVariables)  ?? []
        globalExpressions = try c.decodeIfPresent([PersonalizationExpression].self,
                                                  forKey: .globalExpressions) ?? []
    }

    /// Manifest view shipped to runners.  Pattern families and notebook
    /// checks are save-time authoring concerns — by the time the zip
    /// reaches the runner every generated `.py` is already an ordinary
    /// test script — so both fields are stripped before encode.  Keeping
    /// them in the payload would force every runner binary to know every
    /// `PatternKind` / `NotebookCheckKind` case the server ever introduces
    /// (a new raw value crashes the enum decoder), defeating rolling
    /// deployments.
    public func runnerSanitized() -> TestProperties {
        TestProperties(
            schemaVersion:    schemaVersion,
            gradingMode:      gradingMode,
            requiredFiles:    requiredFiles,
            testSuites:       testSuites,
            timeLimitSeconds: timeLimitSeconds,
            makefile:         makefile,
            starterNotebook:  starterNotebook,
            patternFamilies:  [],
            notebookChecks:   [],
            sections:         sections,
            globalVariables:  globalVariables,
            // Slice 2: expressions are a server-side authoring concern.
            // They never reach the runner — values are evaluated at
            // notebook first-open and substituted into the student
            // working copy before the runner ever sees the assignment.
            globalExpressions: []
        )
    }
}
