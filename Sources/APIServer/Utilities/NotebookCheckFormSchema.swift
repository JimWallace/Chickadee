// APIServer/Utilities/NotebookCheckFormSchema.swift
//
// The single source of truth for the notebook-check editor's per-kind form
// fields.  Each `NotebookCheckKind` declares the inputs its config requires
// (variable name, expected shape, tolerances, …) right here, beside the
// validators in `NotebookCheckKindHandler.swift`.  The schema is serialised
// to JSON and embedded in the assignment editor pages as a
// `<script id="check-schema">` seed; the browser engine in
// `Public/notebook-check-editor.js` renders the form generically from it,
// so the field definitions live in exactly one place instead of being
// hand-coded a fourth time across two Leaf templates and the JS
// reset/populate/build switches.
//
// `formFields(for:)` is an exhaustive switch over `NotebookCheckKind`: a new
// kind fails to compile until it declares its fields, mirroring the
// compile-time guarantee `notebookCheckKindHandler(for:)` already provides
// for rendering + validation.  `NotebookCheckFormSchemaTests` pins the
// `required` flags to each kind's validator so the two can't drift.

import Core
import Foundation

/// The HTML control a form field renders as.
enum CheckFormControl: String, Encodable {
    case text
    case number
    case textarea
    case checkbox
    case select
}

/// How the browser engine coerces a field's value when reading it off the
/// form into a `NotebookCheck` JSON property, and serialises it back when
/// populating the form for an edit.
enum CheckFormValueType: String, Encodable {
    /// Trimmed string, always emitted (a required text field).
    case string
    /// Trimmed string, emitted only when non-empty.
    case optionalString
    /// Untrimmed string, always emitted (e.g. CSV bodies where whitespace
    /// is significant).
    case rawString
    /// Untrimmed string, emitted only when its trimmed form is non-empty.
    case optionalRawString
    /// `parseInt`, always emitted (a required integer).
    case int
    /// `parseInt`, emitted only when parseable.
    case optionalInt
    /// `parseFloat`, emitted only when parseable.
    case optionalFloat
    /// Checkbox boolean, always emitted.
    case bool
    /// One of `enumOptions`, always emitted.
    case enumValue = "enum"
    /// One value per non-empty line (trimmed), emitted as an array.
    case stringList
    /// One number per non-empty line, or a JSON list literal, emitted as a
    /// numeric array.
    case numberList
}

/// A selectable option for a `.select` (`enum`) field.
struct CheckFormEnumOption: Encodable {
    let value: String
    let label: String
}

/// One input in a notebook-check form.  `name` is the `NotebookCheck` JSON
/// property the value maps to (e.g. `function_exists` uses `variable` with a
/// "Function name" label, since the underlying field is `variable`).
struct CheckFormField: Encodable {
    let name: String
    let control: CheckFormControl
    let valueType: CheckFormValueType
    let label: String
    var required: Bool = false
    var placeholder: String?
    var help: String?
    var rows: Int?
    var enumOptions: [CheckFormEnumOption]?
    /// Checkbox default-checked state (only meaningful for `.checkbox`).
    var defaultChecked: Bool = false
    /// Reset/default value for text/number/select controls (the literal the
    /// input is seeded with when authoring a brand-new check).
    var defaultValue: String?
}

/// The full schema: common fields rendered once for every kind, plus the
/// per-kind field lists keyed by `NotebookCheckKind.rawValue`.
struct NotebookCheckFormSchema: Encodable {
    let common: [CheckFormField]
    let kinds: [String: [CheckFormField]]
}

/// Common fields shown for every kind, rendered once outside the per-kind
/// cards.  `hint` is the pervasive instructor-hint field (PR2): authored
/// here, surfaced to students as a "💡 Hint" callout when the check fails.
private let commonCheckFormFields: [CheckFormField] = [
    CheckFormField(
        name: "hint",
        control: .textarea,
        valueType: .optionalString,
        label: "Hint (shown to students when this check fails)",
        placeholder: "e.g. Did you group by the right column before aggregating?",
        rows: 2)
]

/// The per-kind form fields.  Exhaustive over `NotebookCheckKind`: a new case
/// won't compile until it declares its inputs here.  Each field's `required`
/// flag must agree with the matching handler's `validate()` —
/// `NotebookCheckFormSchemaTests` enforces it.
func formFields(for kind: NotebookCheckKind) -> [CheckFormField] {
    switch kind {
    case .dataFrameShape: return dataFrameShapeFormFields
    case .dataFrameColumns: return dataFrameColumnsFormFields
    case .dataFrameEquality: return dataFrameEqualityFormFields
    case .seriesEquality: return seriesEqualityFormFields
    case .numericArrayClose: return numericArrayCloseFormFields
    case .figureCount: return figureCountFormFields
    case .cellContains: return cellContainsFormFields
    case .functionExists: return functionExistsFormFields
    case .variableExists: return variableExistsFormFields
    case .astStructure: return astStructureFormFields
    }
}

private let dataFrameShapeFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "DataFrame variable name on student_module",
        required: true, placeholder: "df"),
    CheckFormField(
        name: "expectedRows", control: .number, valueType: .int,
        label: "Expected rows", required: true),
    CheckFormField(
        name: "expectedCols", control: .number, valueType: .int,
        label: "Expected columns", required: true),
]

private let dataFrameColumnsFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "DataFrame variable name on student_module",
        required: true, placeholder: "df"),
    CheckFormField(
        name: "expectedColumns", control: .textarea, valueType: .stringList,
        label: "Expected columns (one per line, in order)",
        required: true, placeholder: "caseid\nage\nsex\n…", rows: 6),
    CheckFormField(
        name: "columnMatch", control: .select, valueType: .enumValue,
        label: "Match mode",
        enumOptions: [
            CheckFormEnumOption(value: "exact", label: "Exact (order matters)"),
            CheckFormEnumOption(value: "superset", label: "Superset (extras allowed)"),
        ],
        defaultValue: "exact"),
]

private let dataFrameEqualityFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "DataFrame variable name on student_module",
        required: true, placeholder: "df_grouped"),
    CheckFormField(
        name: "expectedCSV", control: .textarea, valueType: .rawString,
        label: "Expected DataFrame (CSV — header row first)",
        required: true, placeholder: "age,sex\n58.0,M\n70.0,M\n…", rows: 8),
    CheckFormField(
        name: "checkDtype", control: .checkbox, valueType: .bool,
        label: "Strict dtype", defaultChecked: true),
    CheckFormField(
        name: "checkLike", control: .checkbox, valueType: .bool,
        label: "Ignore column/row order", defaultChecked: false),
    CheckFormField(
        name: "ignoreIndex", control: .checkbox, valueType: .bool,
        label: "Ignore index", defaultChecked: true),
    CheckFormField(
        name: "rtol", control: .number, valueType: .optionalFloat,
        label: "rtol", placeholder: "1e-5"),
    CheckFormField(
        name: "atol", control: .number, valueType: .optionalFloat,
        label: "atol", placeholder: "1e-8"),
]

private let seriesEqualityFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "Series variable name on student_module",
        required: true, placeholder: "scores"),
    CheckFormField(
        name: "expectedCSV", control: .textarea, valueType: .rawString,
        label: "Expected Series (single-column CSV — header row first)",
        required: true, placeholder: "score\n0.95\n0.88\n…", rows: 8),
]

private let numericArrayCloseFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "Array variable name on student_module",
        required: true, placeholder: "y_pred"),
    CheckFormField(
        name: "expectedArray", control: .textarea, valueType: .numberList,
        label: "Expected values (one number per line, or JSON list)",
        required: true, placeholder: "1.0\n2.5\n3.7\n…", rows: 6),
    CheckFormField(
        name: "rtol", control: .number, valueType: .optionalFloat,
        label: "rtol", placeholder: "1e-7"),
    CheckFormField(
        name: "atol", control: .number, valueType: .optionalFloat,
        label: "atol", placeholder: "0"),
]

private let figureCountFormFields: [CheckFormField] = [
    CheckFormField(
        name: "minFigures", control: .number, valueType: .int,
        label: "Minimum number of matplotlib figures the student must produce",
        required: true,
        help:
            "Counted via plt.get_fignums() after the student's notebook is loaded. "
            + "Every plt.figure, plt.subplots, and df.plot contributes.",
        defaultValue: "1")
]

private let cellContainsFormFields: [CheckFormField] = [
    CheckFormField(
        name: "containsText", control: .text, valueType: .string,
        label: "Pattern the student's submission must contain in at least one code cell",
        required: true, placeholder: ".groupby("),
    CheckFormField(
        name: "regex", control: .checkbox, valueType: .bool,
        label: "Interpret as Python regex", defaultChecked: false),
    CheckFormField(
        name: "mustDifferFrom", control: .textarea, valueType: .optionalRawString,
        label:
            "Must differ from this reference (optional — for \"not the same as the example\" exercises)",
        placeholder: "df.groupby(\"sex\")[\"age\"].mean()", rows: 3),
]

private let functionExistsFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "Function name (must be defined in the student notebook and callable)",
        required: true, placeholder: "classify_bmi"),
    CheckFormField(
        name: "expectedArity", control: .number, valueType: .optionalInt,
        label: "Required arity (number of positional parameters — leave blank to skip)",
        placeholder: "(any)",
        help:
            "Useful as a precondition before correctness tests so a missing function "
            + "fails clearly instead of erroring every dependent test."),
]

private let variableExistsFormFields: [CheckFormField] = [
    CheckFormField(
        name: "variable", control: .text, valueType: .string,
        label: "Variable name (must be defined at module level in the student notebook)",
        required: true, placeholder: "df"),
    CheckFormField(
        name: "expectedType", control: .text, valueType: .optionalString,
        label: "Required type (optional — leave blank for any)",
        placeholder: "e.g. int, list, DataFrame, ndarray",
        help:
            "Recognised types include Python builtins (int, float, bool, str, list, "
            + "tuple, dict, set, NoneType) and library types matched by MRO name "
            + "(DataFrame, Series, ndarray); unknown names fall back to a class-name MRO walk."),
]

private let astStructureFormFields: [CheckFormField] = [
    CheckFormField(
        name: "requiredConstructs", control: .textarea, valueType: .stringList,
        label: "Required structural predicates (one per line)",
        required: true, placeholder: "for_loop\nlist_comprehension\nimport:pandas",
        help:
            "Supported: for_loop, while_loop, list_comprehension, lambda, recursion, "
            + "and import:<module> (e.g. import:pandas). Prefix with ! to forbid "
            + "(e.g. !for_loop = \"must NOT use a for-loop\").",
        rows: 5)
]

/// The complete schema, built by mapping every `NotebookCheckKind` to its
/// declared fields plus the common fields.
func notebookCheckFormSchema() -> NotebookCheckFormSchema {
    var kinds: [String: [CheckFormField]] = [:]
    for kind in NotebookCheckKind.allCases {
        kinds[kind.rawValue] = formFields(for: kind)
    }
    return NotebookCheckFormSchema(common: commonCheckFormFields, kinds: kinds)
}

/// The schema serialised to a JSON object literal for the
/// `<script id="check-schema">` seed.  `"{}"` on the (unreachable) encode
/// failure so the page still renders.
func notebookCheckFormSchemaJSON() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(notebookCheckFormSchema()),
        let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
}
