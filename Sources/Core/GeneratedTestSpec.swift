// Core/GeneratedTestSpec.swift
//
// Common envelope shared by the instructor-authored test generators
// (`PatternFamily`, `NotebookCheck`).  Both expand into one or more
// ordinary Python test scripts at manifest-save time; the runner never
// sees the spec, only the rendered files.  This protocol captures *only*
// what the two generators genuinely have in common — a stable id, a
// human-readable label, and spec-level prerequisites.
//
// Deliberately NOT on the protocol: `tier`, `points`, and `sectionID`.
// A `NotebookCheck` carries those once (it renders to exactly one
// script), but a `PatternFamily` does not — its tier/points live in
// `defaults` with per-case overrides, and its section is decided by the
// family's position in the authored suite, not by a field on the spec.
// Forcing them onto the protocol would be a lie for families.
//
// The rendering itself lives in the APIServer target (it emits Python and
// must stay out of Core); see `renderTestSpec(_:context:)` and
// `allGeneratedFilenames(_:)` for the dispatch that turns any spec into
// files.

import Foundation

public protocol GeneratedTestSpec: Codable, Sendable {
    /// Stable id, unique within the assignment, usable as a filename
    /// fragment.  Satisfied by the stored `id` on both conformers.
    var id: String { get }
    /// Human-readable label for the editor and student results view.
    /// `nil` lets the renderer fall back to a generator-specific default.
    var displayName: String? { get }
    /// Spec-level prerequisites — raw script filenames or `family:<id>`
    /// tokens — inherited by every script the spec produces.  Satisfied
    /// by the stored `dependsOn` on both conformers.
    var dependsOn: [String] { get }
}

extension PatternFamily: GeneratedTestSpec {
    /// A family always has a name; surface it as the optional envelope label.
    public var displayName: String? { name }
}

extension NotebookCheck: GeneratedTestSpec {
    // `displayName` is already `name` (an optional); the stored property
    // satisfies the requirement directly.
    public var displayName: String? { name }
}
