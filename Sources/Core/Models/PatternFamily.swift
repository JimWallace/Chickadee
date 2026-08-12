// Core/Models/PatternFamily.swift
//
// A pattern family is an instructor-authored specification that expands into
// a set of ordinary test scripts at manifest-save time.  The canonical spec
// lives inside the test setup manifest (TestProperties.patternFamilies) and
// the rendered scripts are written into the test setup zip alongside
// hand-written ones.  The runner never sees families — it treats the rendered
// files exactly like any other test script.
//
// Each script produced from a family is referenced by a TestSuiteEntry whose
// `generatedBy` field points back at `PatternFamily.id`, so editing or
// deleting a family is routed back through the family editor rather than
// the raw-script endpoints.

import Foundation

/// Template shape used to render a family's cases into Python source.
///
/// v1 implements `boundaryEquality` only: one function, one argument per case,
/// expected value compared with `==`.  `approximateEquality` is the
/// floating-point counterpart: `abs(result - expected) <= tolerance`.
/// Future kinds (e.g. `boundaryBoolean`, `boundaryMultiArg`,
/// `boundaryException`) slot in alongside.
///
/// `CaseIterable` is load-bearing, not convenience: it is what lets the
/// language conformance matrix (`Tests/APITests/LanguageConformanceMatrixTests`)
/// assert that EVERY kind renders in EVERY language. A hand-listed set of kinds
/// in a test is the fail-open shape this codebase has been bitten by three
/// times — see docs/adding-a-xeus-kernel.md.
public enum PatternKind: String, Codable, Sendable, Equatable, CaseIterable {
    case boundaryEquality = "boundary_equality"
    case approximateEquality = "approximate_equality"
    /// Checks that a module-level variable exists on `student_module` and
    /// equals the expected value.  Unlike the equality kinds above this
    /// doesn't call a function — each case's `args` holds a single string
    /// (the variable name), and `functionName` / `paramNames` are ignored.
    case variableEquality = "variable_equality"
    /// Calls the function with each case's args and asserts the result
    /// is an instance of the expected type.  Per-case `expected` holds
    /// a string naming the type — Python builtins (`"int"`, `"list"`,
    /// `"dict"`, `"str"`, `"bool"`, `"float"`, `"tuple"`, `"set"`,
    /// `"NoneType"`) plus a few common library types pandas/numpy
    /// instructors reach for (`"DataFrame"`, `"Series"`, `"ndarray"`).
    /// Useful as a precondition before correctness tests, and as a
    /// teaching tool for type-aware assignments.
    case returnTypeCheck = "return_type_check"
    /// Calls the function and asserts that it raises a specific
    /// exception type for each case's args.  Per-case `expected` is a
    /// string naming the exception class (`"ValueError"`, `"TypeError"`,
    /// `"KeyError"`, etc., or any user-defined exception class).
    /// Useful for input-validation exercises: "this function must raise
    /// `ValueError` when given a negative input."
    case exceptionExpected = "exception_expected"
    /// Calls the function and asserts the call completed within a
    /// max-millisecond budget.  Per-case `expected` is a number
    /// (decoded as Double) for the threshold; `args` are the inputs.
    /// Uses `time.perf_counter()` around the call.  Single-trial
    /// for v1; if jitter becomes a problem, we add a multi-trial
    /// median in a future kind.
    case performanceThreshold = "performance_threshold"
    /// Calls the function with each case's args, captures everything
    /// written to stdout via `contextlib.redirect_stdout`, and asserts
    /// the captured string equals `case.expected` (a string).  A single
    /// trailing newline is trimmed from both sides so `print("hi")`
    /// matches Expected `"hi"`.  The function's return value is
    /// ignored — instructors who care about both stdout and the
    /// return value should write two families (one of each kind).
    case stdoutEquality = "stdout_equality"
    /// Calls the function with each case's args and compares the returned
    /// list to `expected` **ignoring order** — each element is canonicalised
    /// (JSON with sorted keys) and the two canonical multisets are compared.
    /// For functions that return a collection where order is not part of the
    /// contract (e.g. "find all patients with diagnosis X"); a plain
    /// `boundary_equality` would false-fail on a correct-but-reordered result.
    case unorderedEquality = "unordered_equality"
    /// Calls the student's function and an instructor-written REFERENCE
    /// IMPLEMENTATION with the same args, and asserts the two agree. Each case
    /// supplies only inputs; `expected` is not authored and is ignored, because
    /// the expected value is whatever the reference returns at grade time.
    ///
    /// This is the one thing the retired custom-script templates could do that
    /// no kind could (`TestScriptTemplates.swift` records the other eight and
    /// what superseded them). It earns its place where enumerating expected
    /// values is the hard part — a function over a large or awkward input space,
    /// or one whose right answer is easier to *write* than to *tabulate*.
    ///
    /// TWO THINGS TO KNOW BEFORE REACHING FOR IT.
    ///
    /// The reference is rendered into the generated test script, so on a
    /// BROWSER-GRADED assignment it reaches the student's browser along with
    /// every other test script — browser grading runs the suite locally, so it
    /// must. `docs/datasets.md` states the general rule ("the browser cannot
    /// keep a secret") and worker grading is the answer when the reference is
    /// one. Chickadee does not refuse or warn: whether a reference implementation
    /// is a secret is the instructor's judgement, and for many assignments —
    /// a spec the students already have, a slow-but-obvious implementation they
    /// are asked to speed up — it plainly is not.
    ///
    /// And it grades agreement, not correctness. A wrong reference makes a wrong
    /// test that passes for whoever reproduces the same mistake. Validation runs
    /// the instructor's own solution against it, which catches disagreement
    /// between the two but cannot tell you which one is right.
    case differential
}

/// Shared defaults for a family.  Any case may override `tier`, `points`,
/// or `hint` individually.  `tolerance` applies only to kinds that do
/// approximate comparison (`.approximateEquality`); other kinds ignore it.
public struct PatternDefaults: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let points: Int
    public let hint: String?
    /// Maximum absolute difference between `result` and `expected` that
    /// still counts as a pass, for floating-point `.approximateEquality`
    /// families.  When nil the renderer uses a sensible default (1e-6).
    public let tolerance: Double?
    /// Family-level per-test execution time limit (seconds) applied to every
    /// generated entry in this family — the cases and the auto-existence
    /// guard.  A case may override it (`PatternCase.timeLimitSeconds`); when
    /// both are nil the entry inherits the assignment-wide default.
    public let timeLimitSeconds: Int?

    public init(
        tier: TestTier = .pub, points: Int = 1, hint: String? = nil,
        tolerance: Double? = nil, timeLimitSeconds: Int? = nil
    ) {
        self.tier = tier
        self.points = points
        self.hint = hint
        self.tolerance = tolerance
        self.timeLimitSeconds = timeLimitSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decodeIfPresent(TestTier.self, forKey: .tier) ?? .pub
        points = try c.decodeIfPresent(Int.self, forKey: .points) ?? 1
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance)
        timeLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .timeLimitSeconds)
    }
}

/// One case in a pattern family.  Renders to a single `.py` script whose name
/// is derived deterministically from `family.id` and `case.key`.
public struct PatternCase: Codable, Equatable, Sendable {
    /// Short identifier used in the generated filename.  Should be valid
    /// as part of a filename (letters, digits, underscore).
    public let key: String
    /// Human-readable description; becomes the `# Test: …` header of the
    /// generated script and the display name shown to students in results.
    public let label: String
    /// Arguments passed to the function, in parameter order.  Array length
    /// must match the family's `paramNames` count.
    public let args: [JSONValue]
    /// Parallel to `args`: `false` at position `i` means the instructor
    /// intentionally left the cell empty so Python's own default value for
    /// that parameter should be used at test time (the renderer omits the
    /// argument from the function call).  Empty `[]` means "all provided"
    /// — the pre-v0.4.94 behaviour.  Length, when non-empty, must match
    /// `args.count`.  Distinguishing "omitted" from "None" via a parallel
    /// flag keeps `args[i]` faithful to the literal the instructor typed
    /// (a case genuinely passing `None` round-trips correctly).
    public let argsProvided: [Bool]
    /// Parallel to `args`: when non-nil at position `i`, the instructor
    /// wrote `$<name>` in the cell and wants the generated test to pass
    /// the family variable `<name>` (bare identifier) instead of the
    /// literal in `args[i]`.  The literal slot still carries a
    /// placeholder value (typically `.null`) so the array shape stays
    /// aligned with `paramNames`, but the renderer ignores it when
    /// `argVarRefs[i]` is set.  Empty `[]` means "no variable refs" —
    /// the pre-v0.4.94 behaviour.  Length, when non-empty, must match
    /// `args.count`.
    public let argVarRefs: [String?]
    /// Value compared with `==` against the function's return.
    public let expected: JSONValue
    /// When non-nil, the expected value is resolved per-student at grading
    /// time from the personalization input named here (a global or section
    /// `=` expression row), instead of the literal `expected`.  The renderer
    /// emits `expected = <name>` — a bare identifier defined by the
    /// per-student `_ck_inputs` preamble — rather than baking a literal.  nil
    /// preserves the pre-personalization behaviour (literal `expected`).
    public let expectedVarRef: String?
    /// Per-case hint shown at the end of every failure message.  When nil,
    /// the family's `defaults.hint` is used instead.
    public let hint: String?
    /// Per-case tier override.  When nil, `defaults.tier` is used.
    public let tier: TestTier?
    /// Per-case points override.  When nil, `defaults.points` is used.
    public let points: Int?
    /// Per-case execution time limit (seconds).  When nil, the family default
    /// (`defaults.timeLimitSeconds`) applies; when both are nil the generated
    /// entry inherits the assignment-wide default.
    public let timeLimitSeconds: Int?
    /// Disabled cases remain in the spec but are not rendered into the zip.
    public let enabled: Bool

    public init(
        key: String, label: String, args: [JSONValue], expected: JSONValue,
        argsProvided: [Bool] = [], argVarRefs: [String?] = [],
        expectedVarRef: String? = nil,
        hint: String? = nil, tier: TestTier? = nil, points: Int? = nil,
        timeLimitSeconds: Int? = nil,
        enabled: Bool = true
    ) {
        self.key = key
        self.label = label
        self.args = args
        self.argsProvided = argsProvided.count == args.count ? argsProvided : []
        self.argVarRefs = argVarRefs.count == args.count ? argVarRefs : []
        self.expected = expected
        self.expectedVarRef = expectedVarRef
        self.hint = hint
        self.tier = tier
        self.points = points
        self.timeLimitSeconds = timeLimitSeconds
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        args = try c.decodeIfPresent([JSONValue].self, forKey: .args) ?? []
        let decodedProvided = try c.decodeIfPresent([Bool].self, forKey: .argsProvided) ?? []
        argsProvided = decodedProvided.count == args.count ? decodedProvided : []
        let decodedVarRefs = try c.decodeIfPresent([String?].self, forKey: .argVarRefs) ?? []
        argVarRefs = decodedVarRefs.count == args.count ? decodedVarRefs : []
        expected = try c.decode(JSONValue.self, forKey: .expected)
        expectedVarRef = try c.decodeIfPresent(String.self, forKey: .expectedVarRef)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        tier = try c.decodeIfPresent(TestTier.self, forKey: .tier)
        points = try c.decodeIfPresent(Int.self, forKey: .points)
        timeLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .timeLimitSeconds)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// A family-scoped named value (dict / list / scalar) that is prepended as
/// a Python assignment to every generated test in this family.  Case args
/// can reference a variable by typing `$name` — the renderer emits the
/// bare identifier (e.g. `patient_database`) instead of the literal.
///
/// Scope is per-family in v0.4.94; if a setup-level variable table becomes
/// useful we can promote this struct onto `TestProperties` without a
/// breaking change to the per-family spec.
public struct FamilyVariable: Codable, Equatable, Sendable {
    /// An identifier in the ASSIGNMENT'S language — validated against that
    /// language's keywords + identifier syntax by `PatternFamilyValidator`,
    /// not against Python's on every assignment.  Must be unique within the
    /// family.
    public let name: String
    /// The value bound to `name` in the generated test.  Any JSON-expressible
    /// Python literal (scalar, list, dict) works; nesting is free.
    public let value: JSONValue

    public init(name: String, value: JSONValue) {
        self.name = name
        self.value = value
    }
}

/// Canonical specification for a pattern family.  Stored in
/// `TestProperties.patternFamilies` as the source of truth; rendering
/// produces `.py` files and matching `TestSuiteEntry` values at save time.
public struct PatternFamily: Codable, Equatable, Sendable {
    /// Stable short id (e.g. `bmi_category_boundaries`).  Must be unique
    /// within the assignment and valid as a filename fragment.
    public let id: String
    /// Human-readable name shown in the editor UI.
    public let name: String
    public let kind: PatternKind
    /// Python function under test (looked up on `student_module`).
    public let functionName: String
    /// Parameter names in order.  Used as Python variable names in the
    /// generated source and as column headers in the case-table UI.
    public let paramNames: [String]
    public let defaults: PatternDefaults
    public let cases: [PatternCase]
    /// Family-scoped variables prepended to every generated test.  Each
    /// `FamilyVariable` emits one `name = <pythonLiteral>` line before
    /// the case's declarations; arg cells may reference these by name
    /// (via the `$name` editor syntax, which round-trips as a
    /// `PatternArg.variable` in `PatternCase.args`… once the wire format
    /// switches over — see v0.4.94's migration path in v0.4.95+).
    public let variables: [FamilyVariable]
    /// Family-level prerequisites.  Each entry is either a raw script filename
    /// or a `family:<otherId>` token referring to another family by id.  Every
    /// generated case inherits these dependencies.  When the manifest is
    /// persisted for the runner, `family:<id>` tokens are expanded to the
    /// family's enabled generated filenames so the runner only ever sees
    /// concrete script names.
    public let dependsOn: [String]
    /// Source of the instructor's reference implementation, in the assignment's
    /// language. Required by `.differential` and ignored by every other kind.
    ///
    /// Family-level rather than per-case: one reference answers every case, and
    /// a per-case reference would be a script, not a family.
    ///
    /// Rendered verbatim into each generated test, which is what makes it the
    /// instructor's own code in their own language rather than something
    /// Chickadee translates. It must define the reference under a name the
    /// renderer can call — see `differentialReferenceName`.
    public let referenceImplementation: String?

    public init(
        id: String, name: String, kind: PatternKind,
        functionName: String, paramNames: [String] = [],
        defaults: PatternDefaults = PatternDefaults(),
        cases: [PatternCase] = [],
        variables: [FamilyVariable] = [],
        dependsOn: [String] = [],
        referenceImplementation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.functionName = functionName
        self.paramNames = paramNames
        self.defaults = defaults
        self.cases = cases
        self.variables = variables
        self.dependsOn = dependsOn
        self.referenceImplementation = referenceImplementation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(PatternKind.self, forKey: .kind)
        functionName = try c.decode(String.self, forKey: .functionName)
        paramNames = try c.decodeIfPresent([String].self, forKey: .paramNames) ?? []
        defaults = try c.decodeIfPresent(PatternDefaults.self, forKey: .defaults) ?? PatternDefaults()
        cases = try c.decodeIfPresent([PatternCase].self, forKey: .cases) ?? []
        variables = try c.decodeIfPresent([FamilyVariable].self, forKey: .variables) ?? []
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        referenceImplementation = try c.decodeIfPresent(
            String.self, forKey: .referenceImplementation)
    }
}

extension PatternFamily {
    /// A copy carrying different `dependsOn`, preserving every other field.
    ///
    /// Exists because the suite-edit path used to rebuild the family inline
    /// when the editor sent the dependency at row level, listing the fields it
    /// knew about — and a field added later was silently dropped. That already
    /// happened once, to `variables`: an `argVarRefs` reference failed
    /// validation on the next save, for a family the author had not touched.
    /// `referenceImplementation` would have been the second.
    ///
    /// One copy, beside the property list, pinned by a `Mirror`-based test that
    /// fails when any stored property does not survive — so the next field is
    /// caught by a test rather than by an instructor.
    public func replacingDependsOn(_ newDependsOn: [String]) -> PatternFamily {
        PatternFamily(
            id: id, name: name, kind: kind,
            functionName: functionName, paramNames: paramNames,
            defaults: defaults, cases: cases,
            variables: variables,
            dependsOn: newDependsOn,
            referenceImplementation: referenceImplementation)
    }

    /// The name the generated `.differential` test binds the reference under,
    /// and therefore the name the instructor's source must define.
    ///
    /// Derived from the function under test rather than fixed, so a family can
    /// name its reference after what it references and two families in one
    /// suite cannot collide.
    ///
    /// `ck_ref_`, NOT `_ck_ref_`, even though every other harness name in this
    /// codebase leads with an underscore: R forbids a leading-underscore
    /// identifier outright, which is the same rule that makes the per-student
    /// inputs file bind `.ck_inputs` rather than `_ck`. One spelling has to
    /// work in all six languages, because the instructor types it.
    /// The name the generated differential test calls, and the name the
    /// instructor's reference implementation must define.
    ///
    /// DOTS BECOME UNDERSCORES, because a function name is not always a bare
    /// identifier. Java targets are qualified (`Solution.f`, since Java has no
    /// free functions and a public class must live in a file of its own name),
    /// and `ck_ref_Solution.f` is not a legal identifier in any language — it
    /// made the generated test fail to compile AND made the save-time validator
    /// demand a name no instructor could write. Both halves read this one
    /// property, so sanitizing here fixes them together and cannot let them
    /// disagree.
    ///
    /// No language parameter, deliberately: `.` is not legal in an identifier
    /// in any of the six other languages either, so replacing it is right for
    /// all of them rather than a Java special case. The one language it could
    /// affect is R, whose identifiers genuinely may contain dots (`my.fn` →
    /// `ck_ref_my_fn` rather than `ck_ref_my.fn`). No fixture or stored family
    /// uses a dotted function name, and the change surfaces as a loud
    /// validation error naming the expected name rather than a silent
    /// mis-generation.
    public var differentialReferenceName: String {
        "ck_ref_" + functionName.replacingOccurrences(of: ".", with: "_")
    }
}

extension PatternCase {
    /// Hint applied to this case: the case's own hint if set, otherwise the
    /// family defaults, otherwise nil.
    public func resolvedHint(defaults: PatternDefaults) -> String? {
        if let h = hint, !h.isEmpty { return h }
        return defaults.hint
    }

    /// Tier applied to this case: override if set, else family default.
    public func resolvedTier(defaults: PatternDefaults) -> TestTier {
        tier ?? defaults.tier
    }

    /// Points applied to this case: override if set, else family default.
    public func resolvedPoints(defaults: PatternDefaults) -> Int {
        points ?? defaults.points
    }

    /// Per-test time limit (seconds) applied to this case: the case's own
    /// override if set, else the family default, else nil (inherit the
    /// assignment-wide default).
    public func resolvedTimeLimit(defaults: PatternDefaults) -> Int? {
        timeLimitSeconds ?? defaults.timeLimitSeconds
    }
}
