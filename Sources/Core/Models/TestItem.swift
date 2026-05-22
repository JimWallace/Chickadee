// Core/Models/TestItem.swift
//
// One entry in the unified "test item" list — a pattern family OR a notebook
// check.  Both are instructor-authored specs that expand into generated `.py`
// test scripts at manifest-save time (see PatternFamily / NotebookCheck), and
// the editor UI presents them as flavours of the same "add a test" action.
// `TestItem` is the single type server + UI code iterates so neither has to
// branch on "is this a family or a check" for the shared envelope concerns
// (id, display name, prerequisites).
//
// The two payload structs stay intact rather than being flattened into one
// field-soup type: each keeps the shape it actually uses (a family's table of
// cases vs a check's per-kind config).  `TestItem` is a tagged `enum` over them
// plus a thin set of envelope accessors.
//
// Wire format is a discriminated union: `{ "type": "family", "spec": {…} }`
// or `{ "type": "check", "spec": {…} }`.  Stored in
// `TestProperties.testItems`; legacy manifests (which carry separate
// `patternFamilies` / `notebookChecks` arrays) migrate to it on read.

import Foundation

/// Discriminates the two test-item flavours without forcing callers to
/// pattern-match the full payload when they only need the kind.
public enum TestItemType: String, Codable, Sendable, Equatable {
    case family
    case check
}

public enum TestItem: Codable, Equatable, Sendable {
    case family(PatternFamily)
    case check(NotebookCheck)

    // MARK: - Flavour accessors

    public var type: TestItemType {
        switch self {
        case .family: return .family
        case .check: return .check
        }
    }

    /// The wrapped pattern family, or nil when this item is a check.
    public var family: PatternFamily? {
        if case .family(let f) = self { return f }
        return nil
    }

    /// The wrapped notebook check, or nil when this item is a family.
    public var check: NotebookCheck? {
        if case .check(let c) = self { return c }
        return nil
    }

    // MARK: - Shared envelope accessors
    //
    // Section membership is intentionally NOT exposed here: it is a
    // suite-position concern carried on the generated `TestSuiteEntry`
    // (and on `AuthoredSuiteItem` during a save), not on the spec.  A
    // family carries no section field at all, so there is nothing to
    // surface uniformly.

    /// Stable id, unique within the assignment.
    public var id: String {
        switch self {
        case .family(let f): return f.id
        case .check(let c): return c.id
        }
    }

    /// Instructor-facing display name.  A family always has one; a check's
    /// is optional (the renderer falls back to a kind-derived label).
    public var displayName: String? {
        switch self {
        case .family(let f): return f.name
        case .check(let c): return c.name
        }
    }

    /// Prerequisites in authored form — raw script filenames or
    /// `family:<id>` tokens, expanded server-side before the manifest is
    /// persisted for the runner.
    public var dependsOn: [String] {
        switch self {
        case .family(let f): return f.dependsOn
        case .check(let c): return c.dependsOn
        }
    }

    // MARK: - Codable (discriminated union)

    private enum CodingKeys: String, CodingKey {
        case type
        case spec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(TestItemType.self, forKey: .type)
        switch type {
        case .family:
            self = .family(try c.decode(PatternFamily.self, forKey: .spec))
        case .check:
            self = .check(try c.decode(NotebookCheck.self, forKey: .spec))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .family(let f):
            try c.encode(TestItemType.family, forKey: .type)
            try c.encode(f, forKey: .spec)
        case .check(let ch):
            try c.encode(TestItemType.check, forKey: .type)
            try c.encode(ch, forKey: .spec)
        }
    }
}
