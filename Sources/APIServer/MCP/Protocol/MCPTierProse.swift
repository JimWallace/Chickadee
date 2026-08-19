// APIServer/MCP/Protocol/MCPTierProse.swift
//
// How the test tiers are SPELLED in the agent-facing copy — the `initialize`
// instructions, every tool description, and the error messages a rejected call
// reads back — derived from `TestTier.allCases` in one place.
//
// WHY THIS EXISTS. Nine hand-typed strings across the MCP surface advertised a
// tier `TestTier` has never had: `student`. The schema enum offered it, so an
// agent could pass it validation and then be rejected by
// `TestTier(rawValue:)` one layer down, with an error message that listed the
// same impossible value back. The web suite editor, meanwhile, coerced an
// unrecognized tier to `.pub` rather than refusing it, so the same string was
// accepted-and-silently-changed on one door and rejected on another.
//
// This is the shape `MCPLanguageProse` was written for, one type over: prose is
// the surface no compiler and no `allCases` test reaches, so a list written
// once stays written. The fix is the same fix — the RENDERINGS live here, no
// call site holds a tier name, and `MCPTierCoverageTests` fails if a hand-typed
// list reappears anywhere in the served catalog.
//
// Adding or removing a tier requires no edit to this file and no edit to any
// copy that uses it.

import Core

/// The test tiers, rendered for the places agent-facing copy needs them.
enum MCPTierProse {

    /// Slash-separated alternatives for an inline parenthetical:
    /// `"public/release/secret"`.
    ///
    /// The form tool descriptions use — `"tier (public/release/secret)"` — where
    /// the list is an aside inside a larger sentence.
    static var slashAlternatives: String {
        TestTier.allCases.map(\.rawValue).joined(separator: "/")
    }

    /// Comma list for a "must be one of" error: `"public, release, secret"`.
    ///
    /// Rendered without a conjunction on purpose: this is a set of literal
    /// values a caller must match exactly, not a sentence, and "or" reads as
    /// though the last item were somehow different from the rest.
    static var oneOfList: String {
        TestTier.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// `oneOfList` plus the pseudo-tier `support` — a bundled file that is never
    /// run, so it is not a `TestTier` case and cannot be derived from one.
    ///
    /// The only rendering that names a value by hand, because `support` is
    /// genuinely not a tier. Kept beside its siblings so the exception is
    /// visible rather than inlined at the one call site that needs it.
    static var oneOfListWithSupport: String {
        "\(oneOfList), \(TestTierValues.supportPseudoTier)"
    }
}
