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
public enum PatternKind: String, Codable, Sendable, Equatable {
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

    public init(tier: TestTier = .pub, points: Int = 1, hint: String? = nil,
                tolerance: Double? = nil) {
        self.tier = tier
        self.points = points
        self.hint = hint
        self.tolerance = tolerance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier      = try c.decodeIfPresent(TestTier.self, forKey: .tier)      ?? .pub
        points    = try c.decodeIfPresent(Int.self,      forKey: .points)    ?? 1
        hint      = try c.decodeIfPresent(String.self,   forKey: .hint)
        tolerance = try c.decodeIfPresent(Double.self,   forKey: .tolerance)
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
    /// Per-case hint shown at the end of every failure message.  When nil,
    /// the family's `defaults.hint` is used instead.
    public let hint: String?
    /// Per-case tier override.  When nil, `defaults.tier` is used.
    public let tier: TestTier?
    /// Per-case points override.  When nil, `defaults.points` is used.
    public let points: Int?
    /// Disabled cases remain in the spec but are not rendered into the zip.
    public let enabled: Bool

    public init(key: String, label: String, args: [JSONValue], expected: JSONValue,
                argsProvided: [Bool] = [], argVarRefs: [String?] = [],
                hint: String? = nil, tier: TestTier? = nil, points: Int? = nil,
                enabled: Bool = true) {
        self.key = key
        self.label = label
        self.args = args
        self.argsProvided = argsProvided.count == args.count ? argsProvided : []
        self.argVarRefs   = argVarRefs.count   == args.count ? argVarRefs   : []
        self.expected = expected
        self.hint = hint
        self.tier = tier
        self.points = points
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key      = try c.decode(String.self, forKey: .key)
        label    = try c.decode(String.self, forKey: .label)
        args     = try c.decodeIfPresent([JSONValue].self, forKey: .args) ?? []
        let decodedProvided = try c.decodeIfPresent([Bool].self, forKey: .argsProvided) ?? []
        argsProvided = decodedProvided.count == args.count ? decodedProvided : []
        let decodedVarRefs = try c.decodeIfPresent([String?].self, forKey: .argVarRefs) ?? []
        argVarRefs   = decodedVarRefs.count == args.count ? decodedVarRefs : []
        expected = try c.decode(JSONValue.self, forKey: .expected)
        hint     = try c.decodeIfPresent(String.self,   forKey: .hint)
        tier     = try c.decodeIfPresent(TestTier.self, forKey: .tier)
        points   = try c.decodeIfPresent(Int.self,      forKey: .points)
        enabled  = try c.decodeIfPresent(Bool.self,     forKey: .enabled) ?? true
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
    /// Python identifier.  Validated against keywords + identifier syntax
    /// in `ManifestValidation`.  Must be unique within the family.
    public let name: String
    /// The value bound to `name` in the generated test.  Any JSON-expressible
    /// Python literal (scalar, list, dict) works; nesting is free.
    public let value: JSONValue

    public init(name: String, value: JSONValue) {
        self.name  = name
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

    public init(id: String, name: String, kind: PatternKind,
                functionName: String, paramNames: [String] = [],
                defaults: PatternDefaults = PatternDefaults(),
                cases: [PatternCase] = [],
                variables: [FamilyVariable] = [],
                dependsOn: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.functionName = functionName
        self.paramNames = paramNames
        self.defaults = defaults
        self.cases = cases
        self.variables = variables
        self.dependsOn = dependsOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self,            forKey: .id)
        name         = try c.decode(String.self,            forKey: .name)
        kind         = try c.decode(PatternKind.self,       forKey: .kind)
        functionName = try c.decode(String.self,            forKey: .functionName)
        paramNames   = try c.decodeIfPresent([String].self, forKey: .paramNames) ?? []
        defaults     = try c.decodeIfPresent(PatternDefaults.self, forKey: .defaults) ?? PatternDefaults()
        cases        = try c.decodeIfPresent([PatternCase].self,   forKey: .cases)    ?? []
        variables    = try c.decodeIfPresent([FamilyVariable].self, forKey: .variables) ?? []
        dependsOn    = try c.decodeIfPresent([String].self,        forKey: .dependsOn) ?? []
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
}
