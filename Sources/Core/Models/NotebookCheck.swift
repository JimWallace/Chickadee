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
                expectedArray: [Double]? = nil) {
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
    }
}
