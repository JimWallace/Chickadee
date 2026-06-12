// APIServer/Routes/Web/SuiteRowContexts.swift
//
// Per-row Leaf view-context types shared by the new-assignment and
// edit-assignment pages.  Split from the original
// `AssignmentContextTypes.swift`.

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

    /// Empty string when displayName is nil — Leaf doesn't support `??` in templates.
    var displayNameOrEmpty: String { displayName ?? "" }

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
        case displayNameOrEmpty
        case displayNameOrStem
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
        try container.encode(displayNameOrEmpty, forKey: .displayNameOrEmpty)
        try container.encode(displayNameOrStem, forKey: .displayNameOrStem)
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
