// Core/Models/NotebookCheck.swift
//
// A notebook check is an instructor-authored single-shot assertion about a
// student's notebook submission.  Distinct from `PatternFamily`, which
// exercises a function with a table of cases.  Each NotebookCheck expands
// into exactly one generated Python test script at manifest-save time.
//
// Where families ask "does `classify_bmi(18.49)` return `\"underweight\"`?",
// checks ask "is the student's `df` a (250, 13) DataFrame?", "did the
// student produce ≥ 2 figures under section 'Exercise 4'?", "is the
// markdown after Exercise 6 filled in?", etc.  v1 ships only
// `.dataFrameShape`.
//
// The generated script is a `TestSuiteEntry` whose `generatedByCheck` field
// points back at `NotebookCheck.id`.  Raw-script-edit endpoints refuse to
// mutate it; edits flow through the check editor instead.

import Foundation

/// Kind discriminator.  Future kinds (`.figureCount`, `.markdownPresent`,
/// `.cellContains`) slot in alongside.  Each kind is rendered by a
/// dedicated renderer; the validator enforces that the kind-specific
/// fields below are present and well-formed.
public enum NotebookCheckKind: String, Codable, Sendable, Equatable {
    /// Asserts that a named module-level DataFrame in the student notebook
    /// has exactly `expectedRows × expectedCols` shape.  Required fields:
    /// `variable`, `expectedRows`, `expectedCols`.
    case dataFrameShape = "data_frame_shape"
    /// Asserts that a named module-level DataFrame's columns match an
    /// instructor-provided list.  Required fields: `variable`,
    /// `expectedColumns`.  Optional `columnMatch` chooses between exact
    /// match (order matters; default) and superset match (the student's
    /// DataFrame must contain at least the listed columns; order
    /// irrelevant).
    case dataFrameColumns = "data_frame_columns"
    /// Asserts that a named module-level DataFrame matches an expected
    /// DataFrame via `pandas.testing.assert_frame_equal`.  Required
    /// fields: `variable`, `expectedCSV`.  Optional toggles control
    /// dtype strictness, order sensitivity, float tolerance, and index
    /// handling.  The CSV is written to the test setup zip as a
    /// sidecar file (`_expected_<id>.csv`) at save time; the generated
    /// test reads it and runs the assertion.
    case dataFrameEquality = "data_frame_equality"
    /// Asserts that a named module-level Series matches an expected
    /// Series via `pandas.testing.assert_series_equal`.  Required
    /// fields: `variable`, `expectedCSV` (single-column CSV).  Same
    /// toggles as `.dataFrameEquality`.
    case seriesEquality = "series_equality"
    /// Asserts that a named module-level numeric array (list, ndarray,
    /// or anything `np.asarray`-coercible) is element-wise close to an
    /// expected array via `numpy.testing.assert_allclose`.  Required
    /// fields: `variable`, `expectedArray`.  Optional `rtol` / `atol`
    /// tune tolerance; numpy's defaults (rtol=1e-7, atol=0) apply when
    /// absent.
    case numericArrayClose = "numeric_array_close"
    /// Asserts that the student notebook produced at least
    /// `minFigures` matplotlib figures by the end of execution.  Reads
    /// matplotlib's global figure registry via `plt.get_fignums()`
    /// after `test_runtime.py` has loaded the student module, so no
    /// special instrumentation is needed.  Required field: `minFigures`.
    case figureCount = "figure_count"
    /// Asserts that the student's submission source contains a given
    /// substring (or regex) in at least one code cell.  Optional
    /// `mustDifferFrom` flags cases where the cell must NOT be
    /// identical to a reference string (for "not the same as the
    /// example" exercises).  Required field: `containsText`.
    /// Implemented over the preserved `_submission.ipynb` written
    /// to the workspace by `SubmissionNormalizer` (v0.4.114+).
    case cellContains = "cell_contains"
    /// Asserts that a named function exists on the student module
    /// and is callable, optionally with a specific arity (number of
    /// positional parameters).  Required field: `variable` (the
    /// function name).  Optional `expectedArity` enforces a precise
    /// parameter count; varargs (`*args`) match any arity if expected
    /// is at least the number of required positional params.  Use
    /// this as a cheap precondition for downstream tests so a missing
    /// function fails clearly instead of erroring every dependent.
    case functionExists = "function_exists"
    /// Asserts that the student notebook source has (or doesn't have)
    /// specified AST constructs: `for_loop`, `while_loop`,
    /// `list_comprehension`, `lambda`, `recursion`, or
    /// `import:<module>` to require an import.  Negate any predicate
    /// with a leading `!` (e.g. `!for_loop` for "must NOT use a
    /// for-loop").  Reads the preserved `_submission.ipynb`.  v1
    /// supports a fixed predicate vocabulary; instructors can add
    /// raw cell-content checks via `.cellContains` for anything else.
    case astStructure = "ast_structure"
}

/// How a `.dataFrameColumns` check compares the student's column list
/// against the expected list.
public enum ColumnMatchMode: String, Codable, Sendable, Equatable {
    /// Lists must be equal as ordered sequences (same columns, same
    /// order, same count).  Pandas treats column order as semantically
    /// meaningful for positional access (`df.iloc[:, 0]`), so this is
    /// the default.
    case exact
    /// Student's columns must be a superset of expected (every expected
    /// column is present; extras are allowed; order irrelevant).
    case superset
}

/// Canonical specification for a notebook check.  Stored in
/// `TestProperties.notebookChecks` as the source of truth; rendering
/// produces one `.py` file and one matching `TestSuiteEntry` per check
/// at save time.
///
/// Per-kind config fields are loose-typed (`Optional`) so the JSON shape
/// stays flat and adding new kinds doesn't churn the manifest schema.
/// `ManifestValidation` enforces that the right fields are present for
/// each `kind`.
public struct NotebookCheck: Codable, Equatable, Sendable {
    /// Stable short id (e.g. `df_shape_full_dataset`).  Must be unique
    /// within the assignment and valid as a filename fragment.
    public let id: String
    /// Human-readable name shown in the editor UI and as the per-test
    /// display name in the student results view.  When nil, the renderer
    /// falls back to a kind-specific auto-generated label
    /// (e.g. "df shape (250, 13)" for `.dataFrameShape`).
    public let name: String?
    public let kind: NotebookCheckKind
    public let tier: TestTier
    public let points: Int
    /// Prerequisites.  Same syntax as `TestSuiteEntry.dependsOn` —
    /// either a raw script filename or a `family:<id>` token referring
    /// to a pattern family.  Server expands family tokens before
    /// persisting the manifest for the runner.
    public let dependsOn: [String]
    /// Optional section assignment for visual grouping.  References a
    /// `TestSuiteSection.id` from `TestProperties.sections`.  Stale
    /// references are silently rewritten to nil at save time, mirroring
    /// the family path.
    public let sectionID: String?

    // MARK: Per-kind config (presence enforced by validator)

    /// Name of the module-level variable on `student_module` to inspect.
    /// Used by `.dataFrameShape` and `.dataFrameColumns`.  Must be a
    /// valid Python identifier.
    public let variable: String?
    /// `.dataFrameShape`: required row count.
    public let expectedRows: Int?
    /// `.dataFrameShape`: required column count.
    public let expectedCols: Int?
    /// `.dataFrameColumns`: column names the student's DataFrame must
    /// have.  Order is significant under `.exact` matching, ignored
    /// under `.superset`.
    public let expectedColumns: [String]?
    /// `.dataFrameColumns`: how to compare the student's columns
    /// against `expectedColumns`.  Defaults to `.exact` when absent.
    public let columnMatch: ColumnMatchMode?
    /// `.dataFrameEquality` / `.seriesEquality`: the expected value
    /// serialized as CSV.  At save time the apply path writes this
    /// string verbatim to a sidecar file `_expected_<checkID>.csv`
    /// inside the test setup zip; the generated test reads it via
    /// `pd.read_csv(...)` for the assertion.
    public let expectedCSV: String?
    /// `.dataFrameEquality`: forward to `assert_frame_equal(check_dtype=)`.
    /// Defaults to `true` when absent (catch int/float divergence).
    public let checkDtype: Bool?
    /// `.dataFrameEquality`: forward to `assert_frame_equal(check_like=)`.
    /// Defaults to `false` (column/row order matters).
    public let checkLike: Bool?
    /// `.dataFrameEquality` / `.numericArrayClose`: relative tolerance
    /// for float comparison.  Defaults to pandas/numpy convention when
    /// absent.
    public let rtol: Double?
    /// `.dataFrameEquality` / `.numericArrayClose`: absolute tolerance
    /// for float comparison.  Defaults to pandas/numpy convention when
    /// absent.
    public let atol: Double?
    /// `.dataFrameEquality` / `.seriesEquality`: when `true`, both
    /// sides are `reset_index(drop=True)`'d before comparison.  Default
    /// behaviour when absent: `true` (intro students rarely intend
    /// their index to be semantic; comparing index causes confusing
    /// failures).
    public let ignoreIndex: Bool?
    /// `.numericArrayClose`: the expected 1D array as a list of
    /// numbers.  Compared element-wise via
    /// `numpy.testing.assert_allclose(actual, expected, rtol=, atol=)`.
    /// 2D arrays aren't supported in v1; if needed, add a parallel
    /// `expectedArray2D` field rather than overloading this one.
    public let expectedArray: [Double]?
    /// `.figureCount`: minimum number of matplotlib figures the student
    /// notebook must produce.  The renderer reads
    /// `matplotlib.pyplot.get_fignums()` after the student module has
    /// loaded; that registry tracks every Figure ever created (whether
    /// via `plt.figure`, `df.plot`, `subplots()`, etc.) and survives
    /// `plt.show` no-op stubs.
    public let minFigures: Int?
    /// `.cellContains`: substring (or regex) the student's submission
    /// source must contain in at least one code cell.  Plain substring
    /// matching is the default; set `regex` to true to interpret as a
    /// Python regex.
    public let containsText: String?
    /// `.cellContains`: when true, `containsText` is interpreted as a
    /// Python regex pattern (`re.search`).  Default false.
    public let regex: Bool?
    /// `.cellContains`: optional reference string the matched cell's
    /// source must NOT equal (after whitespace normalization).  Used
    /// for "not the same as the example" exercises where the
    /// instructor's seeded code already contains the matching pattern.
    public let mustDifferFrom: String?
    /// `.functionExists`: optional exact-arity check.  When set, the
    /// student function's positional parameter count must equal this
    /// value.  When nil, only existence + callability is checked.
    public let expectedArity: Int?
    /// `.astStructure`: list of structural predicates the student's
    /// code must satisfy.  Each entry is a plain predicate (e.g.
    /// `"for_loop"`) or a negated predicate (e.g. `"!for_loop"`).
    /// Supported: `for_loop`, `while_loop`, `list_comprehension`,
    /// `lambda`, `recursion`, and `import:<module>`.  All listed
    /// predicates must hold for the test to pass.
    public let requiredConstructs: [String]?

    public init(id: String, name: String? = nil, kind: NotebookCheckKind,
                tier: TestTier = .pub, points: Int = 1,
                dependsOn: [String] = [], sectionID: String? = nil,
                variable: String? = nil,
                expectedRows: Int? = nil, expectedCols: Int? = nil,
                expectedColumns: [String]? = nil,
                columnMatch: ColumnMatchMode? = nil,
                expectedCSV: String? = nil,
                checkDtype: Bool? = nil, checkLike: Bool? = nil,
                rtol: Double? = nil, atol: Double? = nil,
                ignoreIndex: Bool? = nil,
                expectedArray: [Double]? = nil,
                minFigures: Int? = nil,
                containsText: String? = nil,
                regex: Bool? = nil,
                mustDifferFrom: String? = nil,
                expectedArity: Int? = nil,
                requiredConstructs: [String]? = nil) {
        self.id              = id
        self.name            = name
        self.kind            = kind
        self.tier            = tier
        self.points          = points
        self.dependsOn       = dependsOn
        self.sectionID       = sectionID
        self.variable        = variable
        self.expectedRows    = expectedRows
        self.expectedCols    = expectedCols
        self.expectedColumns = expectedColumns
        self.columnMatch     = columnMatch
        self.expectedCSV     = expectedCSV
        self.checkDtype      = checkDtype
        self.checkLike       = checkLike
        self.rtol            = rtol
        self.atol            = atol
        self.ignoreIndex     = ignoreIndex
        self.expectedArray   = expectedArray
        self.minFigures      = minFigures
        self.containsText    = containsText
        self.regex           = regex
        self.mustDifferFrom  = mustDifferFrom
        self.expectedArity   = expectedArity
        self.requiredConstructs = requiredConstructs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self,             forKey: .id)
        name            = try c.decodeIfPresent(String.self,    forKey: .name)
        kind            = try c.decode(NotebookCheckKind.self,  forKey: .kind)
        tier            = try c.decodeIfPresent(TestTier.self,  forKey: .tier)            ?? .pub
        points          = try c.decodeIfPresent(Int.self,       forKey: .points)          ?? 1
        dependsOn       = try c.decodeIfPresent([String].self,  forKey: .dependsOn)       ?? []
        sectionID       = try c.decodeIfPresent(String.self,    forKey: .sectionID)
        variable        = try c.decodeIfPresent(String.self,    forKey: .variable)
        expectedRows    = try c.decodeIfPresent(Int.self,       forKey: .expectedRows)
        expectedCols    = try c.decodeIfPresent(Int.self,       forKey: .expectedCols)
        expectedColumns = try c.decodeIfPresent([String].self,  forKey: .expectedColumns)
        columnMatch     = try c.decodeIfPresent(ColumnMatchMode.self, forKey: .columnMatch)
        expectedCSV     = try c.decodeIfPresent(String.self,    forKey: .expectedCSV)
        checkDtype      = try c.decodeIfPresent(Bool.self,      forKey: .checkDtype)
        checkLike       = try c.decodeIfPresent(Bool.self,      forKey: .checkLike)
        rtol            = try c.decodeIfPresent(Double.self,    forKey: .rtol)
        atol            = try c.decodeIfPresent(Double.self,    forKey: .atol)
        ignoreIndex     = try c.decodeIfPresent(Bool.self,      forKey: .ignoreIndex)
        expectedArray   = try c.decodeIfPresent([Double].self,  forKey: .expectedArray)
        minFigures      = try c.decodeIfPresent(Int.self,       forKey: .minFigures)
        containsText    = try c.decodeIfPresent(String.self,    forKey: .containsText)
        regex           = try c.decodeIfPresent(Bool.self,      forKey: .regex)
        mustDifferFrom  = try c.decodeIfPresent(String.self,    forKey: .mustDifferFrom)
        expectedArity   = try c.decodeIfPresent(Int.self,       forKey: .expectedArity)
        requiredConstructs = try c.decodeIfPresent([String].self, forKey: .requiredConstructs)
    }
}
