// APIServer/Utilities/LanguageProse.swift
//
// How a SET of assignment languages is spelled in copy a human or an agent
// reads, derived from `AssignmentLanguage` rather than typed out.
//
// WHY THIS IS SEPARATE FROM `MCPLanguageProse`. That type renders one set — all
// of them — three ways, and its guard (`MCPLanguageCoverageTests`) catches a
// hand-typed list by comparing against the proper prefixes of `allCases`. That
// guard deliberately ignores single-language mentions, because "a cpp
// assignment must be uploadOnly" is legitimate prose and not a list.
//
// Which is exactly how the upload-only sentence went stale. C++ was the only
// upload-only language when that copy was written; Racket made it two, the
// enforcement predicate (`requiresUploadOnlySubmission`) picked the second one
// up because it asks `editorSupport`, and four MCP tool descriptions plus both
// authoring pages went on naming only C++. A Racket author was told nothing and
// found out by being refused at save.
//
// So the general lesson is not "derive the full list" but "derive any list a
// PREDICATE defines". This renders those, and the upload-only set is the first
// caller. A seventh upload-only language changes every sentence below with no
// edit to any of them.

import Core

/// Renders a predicate-defined set of languages as prose.
enum LanguageProse {

    /// The display names of every language satisfying `predicate`, as a
    /// sentence fragment: `"C++ or Racket"`.
    ///
    /// Empty when nothing satisfies it — callers building a sentence around
    /// this should check, since "" makes most sentences ungrammatical.
    static func displayNames(where predicate: (AssignmentLanguage) -> Bool) -> String {
        list(AssignmentLanguage.allCases.filter(predicate).map(\.displayName))
    }

    /// The wire tokens of every language satisfying `predicate`:
    /// `"cpp or racket"`.
    ///
    /// Distinct from `displayNames(where:)` for the reason `MCPLanguageProse`
    /// keeps the same split — an agent sends `cpp`, not `C++`.
    static func tokens(where predicate: (AssignmentLanguage) -> Bool) -> String {
        list(AssignmentLanguage.allCases.filter(predicate).map(\.rawValue))
    }

    /// The languages with no editor kernel, whose assignments must be
    /// upload-only: `"C++ or Racket"` today.
    ///
    /// Reads the same `editorSupport` answer the save-time refusal reads, so
    /// the explanation an instructor is given and the rule they are held to
    /// cannot name different languages.
    static var uploadOnlyDisplayNames: String {
        displayNames(where: requiresUploadOnlySubmission)
    }

    /// `uploadOnlyDisplayNames` as wire tokens, for agent-facing copy.
    static var uploadOnlyTokens: String {
        tokens(where: requiresUploadOnlySubmission)
    }

    /// The languages whose language cannot be derived from their own suite, so
    /// an author must declare it: `"cpp"` today.
    ///
    /// NOT the same set as the upload-only one, though C++ is in both and that
    /// coincidence is what makes the two easy to conflate. This one is about
    /// the generated FILENAME: a C++ test case is a shell wrapper, so the suite
    /// carries no C++ extension to resolve from. Racket generates `.rkt` and is
    /// perfectly derivable despite also being upload-only.
    static var mustDeclareTokens: String {
        tokens(where: { !$0.scriptExtensions.contains($0.generatedScriptExtension) })
    }

    /// `mustDeclareTokens` as display names.
    static var mustDeclareDisplayNames: String {
        displayNames(where: { !$0.scriptExtensions.contains($0.generatedScriptExtension) })
    }

    /// Every wire token, comma-separated with no connector:
    /// `"python, r, lua, octave, cpp, racket"`.
    ///
    /// For an input PLACEHOLDER, where "or" would read as part of the example
    /// rather than as prose. The runner-requirements input on the create page
    /// spelled this list out by hand, directly below a select derived from
    /// `allCases`.
    static var allTokensCSV: String {
        AssignmentLanguage.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// `["a", "b", "c"]` → `"a, b or c"`; a one-element list is itself.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " or " + last
    }
}
