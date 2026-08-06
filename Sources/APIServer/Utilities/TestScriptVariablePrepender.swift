// APIServer/Utilities/TestScriptVariablePrepender.swift
//
// Renders a variable preamble — one line per FamilyVariable, in the target
// language (`name = <pythonLiteral>` for Python, `name <- <rLiteral>` for R) —
// used by:
//
// 1. The pattern-family renderer, which prepends section + family
//    variables (and from Slice 1: global variables) to every generated
//    test case.
// 2. The raw-script save-time pass that inlines section + global variables
//    into instructor-uploaded `.py` and `.R` test scripts, so a hand-written
//    test sees the assignment's literal inputs in either language.
// 3. The notebook substitution pass (consumes the same JSON literal
//    representation via `FamilyVariable.value.pythonLiteral`).
//
// Variable precedence is the caller's responsibility: pass the list in
// the order you want assignments to execute (narrower-shadows-broader
// follows Python's last-assignment-wins).  For Slice 1's combined scope
// this is `globals + section + family`.

import Core
import Foundation

enum TestScriptVariablePrepender {

    /// Returns a newline-joined block of assignments, one per variable —
    /// `name = <pythonLiteral>` for Python, `name <- <rLiteral>` for R.
    /// Empty string when `variables` is empty.  `language` defaults to
    /// `.python`, so generated Python bytes are unchanged.
    static func emit(
        _ variables: [FamilyVariable], language: AssignmentLanguage = .python
    ) -> String {
        switch language {
        case .python:
            return
                variables
                .map { "\($0.name) = \($0.value.pythonLiteral)" }
                .joined(separator: "\n")
        case .r:
            return
                variables
                .map { "\(rIdentifier($0.name)) <- \($0.value.rLiteral)" }
                .joined(separator: "\n")
        case .lua:
            // `local`, which is both the Lua idiom and what keeps a family's
            // variables out of `_G` — the environment the student's submission
            // is loaded beside. A later `local` of the same name shadows an
            // earlier one for the rest of the chunk, which is exactly the
            // `family > section > global` precedence Python gets from
            // last-assignment-wins and R from top-to-bottom evaluation.
            return
                variables
                .map { "local \(luaIdentifier($0.name)) = \($0.value.luaLiteral)" }
                .joined(separator: "\n")
        }
    }

    /// Wraps `emit` with a trailing blank line so callers can use a
    /// fixed format: variables block, blank line, then the original
    /// test-script body.  Empty string when `variables` is empty.
    static func emitBlock(_ variables: [FamilyVariable]) -> String {
        let decls = emit(variables)
        return decls.isEmpty ? "" : decls + "\n\n"
    }

    /// Marker line written above the prepended assignments in raw
    /// instructor-uploaded `.py` test scripts.  Used both as a "do not
    /// edit" cue for the reader and as a sentinel for `stripExistingBlock`
    /// so re-prepending stays idempotent across saves.
    static let rawScriptBannerComment =
        "# === Chickadee inputs: name = value, prepended at save time. Do not edit. ==="

    /// Prepends `variables` to the body of a raw Python test script.
    /// Preserves a leading shebang line on line 1.  Idempotent: any
    /// previously-prepended Chickadee block (identified by the banner
    /// comment) is stripped before the new block is added, so calling
    /// this repeatedly with different `variables` lists produces
    /// stable, deterministic output.
    ///
    /// When `variables` is empty AND the body has no existing block,
    /// returns the body verbatim.  When `variables` is empty AND the
    /// body has an existing block, that block is stripped (cleanup
    /// path for removing all variables).
    static func prependToRawScript(
        _ originalBody: String,
        variables: [FamilyVariable],
        language: AssignmentLanguage = .python
    ) -> String {
        let stripped = stripExistingBlock(originalBody)
        guard !variables.isEmpty else { return stripped }

        let decls = emit(variables, language: language)

        // Detect a leading shebang so we can keep it on line 1.
        if stripped.hasPrefix("#!") {
            let lines = stripped.split(
                separator: "\n",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            let shebang = String(lines.first ?? "")
            let rest = lines.count > 1 ? String(lines[1]) : ""
            return [
                shebang,
                rawScriptBannerComment,
                decls,
                "",
                rest,
            ].joined(separator: "\n")
        }
        return [
            rawScriptBannerComment,
            decls,
            "",
            stripped,
        ].joined(separator: "\n")
    }

    /// Removes a previously-emitted Chickadee inputs block from `body`.
    /// The block is identified by the banner comment; it ends at the
    /// first blank line that follows.  Returns `body` unchanged when
    /// no banner is present.
    static func stripExistingBlock(_ body: String) -> String {
        guard body.contains(rawScriptBannerComment) else { return body }
        var lines =
            body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let startIdx = lines.firstIndex(of: rawScriptBannerComment) else {
            return body
        }
        // Walk forward to find the blank line that closes the block.
        var endIdx = startIdx + 1
        while endIdx < lines.count, !lines[endIdx].isEmpty {
            endIdx += 1
        }
        // Drop lines [startIdx ... endIdx] inclusive (banner + assignments + blank line).
        let endRemoveIdx = min(endIdx + 1, lines.count)
        lines.removeSubrange(startIdx..<endRemoveIdx)
        return lines.joined(separator: "\n")
    }

    /// Convenience for the raw-script save path: returns the script's content
    /// with global + section variables prepended, sourcing the variables from
    /// `manifest`.  The script's own extension names its language — `.py` gets
    /// `name = <pythonLiteral>`, `.R`/`.r` gets `name <- <rLiteral>` — so an
    /// instructor's hand-written test sees the assignment's literal inputs
    /// whichever language they wrote it in.  Anything else (a shell script, a
    /// data file) is returned unchanged.  When `filename` isn't found in
    /// `manifest.testSuites`, no section variables are applied (treated as
    /// "ungrouped").
    static func applyForRawScript(
        filename: String,
        content: String,
        manifest: TestProperties,
        explicitSectionID: String? = nil
    ) -> String {
        guard
            let language = AssignmentLanguage(
                scriptExtension: (filename as NSString).pathExtension)
        else { return content }
        let sectionID: String?
        if let explicitSectionID {
            sectionID = explicitSectionID
        } else {
            sectionID = manifest.testSuites.first(where: { $0.script == filename })?.sectionID
        }
        let sectionVars: [FamilyVariable] = {
            guard let sid = sectionID else { return [] }
            return manifest.sections.first(where: { $0.id == sid })?.variables ?? []
        }()
        return prependToRawScript(
            content, variables: manifest.globalVariables + sectionVars, language: language)
    }
}
