// APIServer/MCP/Protocol/MCPLanguageProse.swift
//
// How the assignment languages are SPELLED in the agent-facing copy — the
// `initialize` instructions and every tool description — derived from
// `AssignmentLanguage.allCases` in one place.
//
// WHY THIS EXISTS, AND WHY IT IS NOT A CONSTANT PER CALL SITE.
// Agent-facing copy is prose, and prose is the one surface no compiler and no
// `allCases` test reaches. A hand-typed language list there is the shape that
// goes stale silently, and it has now done so twice:
//
//   * #1288 found the `initialize` instructions telling every agent that
//     personalization expressions are "Python source" — wrong from the moment R
//     shipped, and wrong for the whole of R's and Lua's existence.
//   * The fix derived THAT sentence's list from `allCases` and stopped there.
//     One language later (Racket, #1308), five other hand-typed lists were
//     still enumerating up to `cpp`: `set_assignment_language` told agents
//     Racket was not a legal value while its own JSON `enum` — derived —
//     accepted it, and four tool descriptions still called expressions Python.
//
// The lesson of the second round is that fixing the string you are looking at
// does not fix the class. So the RENDERINGS live here rather than the lists:
// three ways the same derived set is written, chosen by where it appears, and
// no call site holds a language name at all.
//
// Adding a seventh language requires no edit to this file and no edit to any
// copy that uses it. `MCPLanguageCoverageTests` fails if a hand-typed list
// reappears anywhere in the served catalog.

import Core

/// The assignment languages, rendered for the three places agent-facing copy
/// needs them.
enum MCPLanguageProse {

    /// Prose for a sentence a human or agent reads: `"Python, R, Lua, Octave,
    /// C++ or Racket"`. Display names, Oxford-comma-free, joined with "or".
    ///
    /// Use inside a sentence about what the system supports.
    static var displayNames: String {
        prose(AssignmentLanguage.allCases.map(\.displayName))
    }

    /// Prose for a sentence naming the WIRE TOKENS a caller passes:
    /// `"python, r, lua, octave, cpp or racket"`.
    ///
    /// Distinct from `displayNames` because these are values, not names — an
    /// agent setting `language` sends `cpp`, not `C++`.
    static var tokens: String {
        prose(AssignmentLanguage.allCases.map(\.rawValue))
    }

    /// The alternatives of a JSON string field, as a schema-style union:
    /// `"\"python\" | \"r\" | \"lua\" | \"octave\" | \"cpp\" | \"racket\""`.
    ///
    /// For a field's `description`, where the value set reads better as a union
    /// than as a sentence. The quoting is part of the rendering so no call site
    /// has to escape it.
    static var quotedTokenAlternatives: String {
        AssignmentLanguage.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | ")
    }

    /// `["a", "b", "c"]` → `"a, b or c"`; a one-element list is itself.
    private static func prose(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " or " + last
    }
}
