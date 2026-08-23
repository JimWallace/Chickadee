// APIServer/Routes/Web/SuiteRowContexts.swift
//
// Per-row Leaf view-context types shared by the new-assignment and
// edit-assignment pages.  Split from the original
// `AssignmentContextTypes.swift`.

import Core
import Foundation

/// One section block's server-rendered shell in the suite editor.  Named
/// sections carry a non-empty `sectionID` and `name`; the trailing
/// Ungrouped block has `isUngrouped == true`, a sentinel empty
/// `sectionID`, and no name — the template renders no header for it.
struct SuiteSectionShellRow: Encodable {
    let sectionID: String
    let name: String
    let isUngrouped: Bool
    /// Section-level variables as pre-serialised JSON strings so the
    /// template can emit them into hidden inputs / editable rows without
    /// re-encoding in Leaf (which doesn't handle JSONValue well).  One
    /// `{name, valueJSON}` entry per variable.
    let variables: [SuiteSectionVariableShellRow]
    /// Empty-state flag so the template can hide the "Variables" block
    /// when the section has none (keeps the header clean).
    let hasVariables: Bool
}

struct SuiteSectionVariableShellRow: Encodable {
    let name: String
    /// JSON-encoded value, ready to stuff into an `<input value="">`.
    let valueJSON: String
}

struct CurrentFileLink {
    let name: String
    let url: String
}

struct EditableSuiteRow: Encodable {
    let name: String
    let url: String
    let isTest: Bool
    let tier: String
    let order: Int
    let dependsOn: [String]  // script names of prerequisites; empty == none
    let points: Int  // grade weight; 1 = default (unweighted)
    let displayName: String?  // optional human-readable name shown to students
    /// True when this file is marked a per-student dataset (docs/datasets.md).
    /// Only meaningful on a support row; a test script is never a dataset.
    let isDataset: Bool
    /// Rows each student receives for a dataset row; nil = whole file (and nil
    /// on every non-dataset row).
    let datasetSampleSize: Int?
    /// The column a stratified dataset balances across; nil for a plain row
    /// sample. The control derives the spec's kind from this being set, so it
    /// has to travel with the row or an edit would rewrite a stratified spec
    /// into a plain one.
    let datasetStratumColumn: String?
    /// The spec's derivation steps (docs/datasets.md). Carried so the panel can
    /// render the one shape it edits — and, more importantly, so it can tell
    /// when a spec holds a shape it CANNOT edit and step aside rather than
    /// overwrite it.
    let datasetTransforms: [DatasetTransform]

    /// Empty string when displayName is nil — Leaf doesn't support `??` in templates.
    var displayNameOrEmpty: String { displayName ?? "" }

    /// The sample size as an input-ready string — empty when there is none, so
    /// the number field renders blank rather than "nil" (same reason
    /// `displayNameOrEmpty` exists).
    var datasetSampleSizeText: String { datasetSampleSize.map(String.init) ?? "" }

    /// The stratum column as an input-ready string — empty when there is none.
    var datasetStratumColumnOrEmpty: String { datasetStratumColumn ?? "" }

    /// Whether the Files panel can represent this spec's transforms.
    ///
    /// The panel edits exactly one shape: no transforms, or a single
    /// `missingValues` step. The model is richer than that — an ordered list,
    /// and more kinds to come — so a spec authored through MCP can hold
    /// something the panel has no fields for. Rendering such a spec into the
    /// fields it does have would silently discard the rest on the next edit,
    /// which is the same silent-downgrade shape the stratum column exists to
    /// avoid. So the panel asks first, and shows a disabled control saying the
    /// steps are agent-authored rather than pretending to own them.
    var datasetTransformsEditable: Bool {
        datasetTransforms.isEmpty
            || (datasetTransforms.count == 1 && datasetTransforms[0].kind == .missingValues)
    }

    /// The blanked columns as a comma-separated string — empty when no
    /// `missingValues` step is present.
    var datasetBlankColumnsOrEmpty: String {
        guard datasetTransformsEditable else { return "" }
        return datasetTransforms.first?.columns.joined(separator: ", ") ?? ""
    }

    /// The blank rate as a whole-number percentage for the form, or empty.
    /// Authored as a percentage because that is how an instructor says it; the
    /// stored value is the `0 < rate <= 1` fraction the materializer folds.
    var datasetBlankPercentText: String {
        guard datasetTransformsEditable, let rate = datasetTransforms.first?.rate else { return "" }
        return String(Int((rate * 100).rounded()))
    }

    /// The dataset pair defaults to "not a dataset": every construction site
    /// but the two support-file row builders is describing a test script, and
    /// a script is never a per-student dataset.
    init(
        name: String,
        url: String,
        isTest: Bool,
        tier: String,
        order: Int,
        dependsOn: [String],
        points: Int,
        displayName: String?,
        isDataset: Bool = false,
        datasetSampleSize: Int? = nil,
        datasetStratumColumn: String? = nil,
        datasetTransforms: [DatasetTransform] = []
    ) {
        self.name = name
        self.url = url
        self.isTest = isTest
        self.tier = tier
        self.order = order
        self.dependsOn = dependsOn
        self.points = points
        self.displayName = displayName
        self.isDataset = isDataset
        self.datasetSampleSize = datasetSampleSize
        self.datasetStratumColumn = datasetStratumColumn
        self.datasetTransforms = datasetTransforms
    }

    /// Display name if set, otherwise the filename stem (extension stripped).
    /// Used as the default value of the name input in the assignment editor.
    var displayNameOrStem: String {
        if let n = displayName, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return n }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// JSON-encoded `dependsOn` array for use as an HTML data attribute in Leaf templates.
    var dependsOnJSON: String {
        let data = (try? JSONEncoder().encode(dependsOn)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case isTest
        case tier
        case order
        case dependsOn
        case points
        case displayName
        case isDataset
        case datasetSampleSize
        case datasetStratumColumn
        case displayNameOrEmpty
        case displayNameOrStem
        case datasetSampleSizeText
        case datasetStratumColumnOrEmpty
        // The derivation fields the panel renders. `datasetTransforms` itself is
        // deliberately NOT encoded — Leaf has no use for the array, and the
        // three derived strings are exactly what the control's inputs need.
        case datasetTransformsEditable
        case datasetBlankColumnsOrEmpty
        case datasetBlankPercentText
        case dependsOnJSON
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isTest, forKey: .isTest)
        try container.encode(tier, forKey: .tier)
        try container.encode(order, forKey: .order)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(isDataset, forKey: .isDataset)
        try container.encodeIfPresent(datasetSampleSize, forKey: .datasetSampleSize)
        try container.encodeIfPresent(datasetStratumColumn, forKey: .datasetStratumColumn)
        try container.encode(displayNameOrEmpty, forKey: .displayNameOrEmpty)
        try container.encode(displayNameOrStem, forKey: .displayNameOrStem)
        try container.encode(datasetSampleSizeText, forKey: .datasetSampleSizeText)
        try container.encode(datasetStratumColumnOrEmpty, forKey: .datasetStratumColumnOrEmpty)
        try container.encode(datasetTransformsEditable, forKey: .datasetTransformsEditable)
        try container.encode(datasetBlankColumnsOrEmpty, forKey: .datasetBlankColumnsOrEmpty)
        try container.encode(datasetBlankPercentText, forKey: .datasetBlankPercentText)
        try container.encode(dependsOnJSON, forKey: .dependsOnJSON)
    }
}

/// A single row in the suite table representing a pattern family.  Sits
/// alongside `EditableSuiteRow` values — the family expands into N
/// generated scripts at save time, but in the editor UI it's one draggable
/// entry with the family's metadata.
struct FamilySuiteRow: Encodable {
    let id: String
    let name: String
    let functionName: String
    let tier: String  // family default tier
    let caseCount: Int
    let totalPoints: Int  // sum of per-case resolved points

    /// Leaf-friendly formatted case count suffix: "1 case" or "N cases".
    var caseCountText: String { caseCount == 1 ? "1 case" : "\(caseCount) cases" }

    enum CodingKeys: String, CodingKey {
        case id, name, functionName, tier, caseCount, totalPoints, caseCountText
    }

    func encode(to encoder: Encoder) throws {
        // Synthesized Encodable would skip `caseCountText` because it's a
        // computed property; Leaf needs it to render the row subtitle, so
        // we emit it explicitly here.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(functionName, forKey: .functionName)
        try c.encode(tier, forKey: .tier)
        try c.encode(caseCount, forKey: .caseCount)
        try c.encode(totalPoints, forKey: .totalPoints)
        try c.encode(caseCountText, forKey: .caseCountText)
    }
}
