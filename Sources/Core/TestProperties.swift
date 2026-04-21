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
public struct TestSuiteEntry: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let script: String       // e.g. "01_public.py"
    public let name: String?        // optional display name shown to students
    public let dependsOn: [String]  // script names of prerequisites; empty == no deps
    public let points: Int          // grade weight; 1 = default (unweighted)
    public let generatedBy: String? // pattern family id, nil for hand-written scripts

    public init(tier: TestTier, script: String, name: String? = nil,
                dependsOn: [String] = [], points: Int = 1,
                generatedBy: String? = nil) {
        self.tier        = tier
        self.script      = script
        self.name        = name
        self.dependsOn   = dependsOn
        self.points      = points
        self.generatedBy = generatedBy
    }

    public init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        tier        = try c.decode(TestTier.self,    forKey: .tier)
        script      = try c.decode(String.self,      forKey: .script)
        name        = try c.decodeIfPresent(String.self,   forKey: .name)
        dependsOn   = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        points      = try c.decodeIfPresent(Int.self, forKey: .points) ?? 1
        generatedBy = try c.decodeIfPresent(String.self, forKey: .generatedBy)
    }
}

/// Optional Makefile step to run before tests.
public struct MakefileConfig: Codable, Equatable, Sendable {
    public let target: String?     // nil means bare `make` with no target
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

    public init(schemaVersion: Int = 1,
                gradingMode: GradingMode = .worker,
                requiredFiles: [String] = [],
                testSuites: [TestSuiteEntry] = [],
                timeLimitSeconds: Int = 10,
                makefile: MakefileConfig? = nil,
                starterNotebook: String? = nil,
                patternFamilies: [PatternFamily] = []) {
        self.schemaVersion    = schemaVersion
        self.gradingMode      = gradingMode
        self.requiredFiles    = requiredFiles
        self.testSuites       = testSuites
        self.timeLimitSeconds = timeLimitSeconds
        self.makefile         = makefile
        self.starterNotebook  = starterNotebook
        self.patternFamilies  = patternFamilies
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
    }
}
