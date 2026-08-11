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
        _ variables: [FamilyVariable], language: AssignmentLanguage
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
        case .octave:
            return
                variables
                .map { "\(octaveIdentifier($0.name)) = \($0.value.octaveLiteral);" }
                .joined(separator: "\n")
        case .cpp:
            // Nothing, and the empty answer is the correct one — see
            // `supportsRawScriptInlining`, which stops this being reached.
            //
            // This arm used to emit POSIX SHELL assignments, on the reasoning
            // that a C++ assignment's graded scripts are `.sh` wrappers. True,
            // but it made the arm unreachable-or-wrong: a `.sh` file resolves
            // to no language at all (no language claims that extension), so the
            // only way in was a hand-added `.cpp`/`.h`/`.hpp` suite entry —
            // which would have received shell assignments inside a C++ file.
            // No caller ever passed `.cpp` here.
            return ""
        case .racket:
            // `(define name value)` — top-level definitions in the generated
            // test's own module. Unlike C++'s shell arm there is no scalar
            // restriction: every JSONValue has a Racket rendering, so a list
            // or hash global inlines as faithfully as an integer.
            return
                variables
                .map { "(define \($0.name) \($0.value.racketLiteral))" }
                .joined(separator: "\n")
        case .java:
            // Nothing, like C++ — but for a DIFFERENT reason, and the
            // difference matters because C++'s reason does not apply here. A
            // hand-written `.java` suite entry IS executable (single-file
            // source mode), so unlike a bare `.cpp` there genuinely is a point
            // at which an inlined block would be read.
            //
            // What stops it is Java's syntax: a `.java` file is a class
            // declaration, and there is no top-level statement position to
            // prepend `int n = 5;` to. Any inlined block would have to be
            // injected INSIDE a class body — which means knowing where the
            // class starts, in a file the instructor wrote. That is a text
            // transformation on someone else's source with a syntax error as
            // the failure mode, so it is refused rather than attempted; see
            // `supportsRawScriptInlining`. Inputs reach Java through
            // `_ck_inputs.java` instead.
            return ""
        }
    }

    // `emitBlock(_:)` used to live here: `emit` plus a trailing blank line,
    // with no language parameter and therefore Python declarations for every
    // assignment. Nothing in Sources/ called it — only two test assertions did,
    // which is why the missing parameter never surfaced. Its callers now use
    // `emit` directly and say which language they mean.

    /// Whether a hand-written test script in `language` can host an inlined
    /// variable block at all.
    ///
    /// False for C++ alone, and not as a limitation — as a fact about what a
    /// graded C++ "script" is. C++ test cases are `.sh` wrappers that compile a
    /// translation unit; a bare `.cpp` in the suite is not something the runner
    /// executes, so there is no point at which an inlined declaration would be
    /// read. Inputs reach C++ through `_ck_inputs.hpp` instead.
    ///
    /// Exhaustive, so a seventh language answers it rather than inheriting an
    /// assumption.
    static func supportsRawScriptInlining(_ language: AssignmentLanguage) -> Bool {
        switch language {
        case .python, .r, .lua, .octave, .racket: return true
        // False for both compiled languages, for two different reasons — see
        // the corresponding arms of `emit`. C++: a bare `.cpp` is never
        // executed, so nothing would read the block. Java: a `.java` file has
        // no top-level statement position to prepend one to.
        case .cpp, .java: return false
        }
    }

    /// The banner text, without its comment marker.  Shared by every
    /// language's banner so `stripExistingBlock` can recognise all of them.
    private static let rawScriptBannerBody =
        " === Chickadee inputs: name = value, prepended at save time. Do not edit. ==="

    /// Marker line written above the prepended assignments in a raw
    /// instructor-uploaded test script.  Used both as a "do not edit" cue for
    /// the reader and as a sentinel for `stripExistingBlock` so re-prepending
    /// stays idempotent across saves.
    ///
    /// COMMENTED IN THE SCRIPT'S OWN LANGUAGE.  This was a single `#`-prefixed
    /// constant for every language, which is a comment in Python, R, Octave and
    /// shell and a syntax error in the other three: `#` is Lua's length
    /// operator, starts a Racket reader form, and is a C++ preprocessor
    /// directive.  A Lua or Racket assignment with global inputs plus a
    /// hand-written test produced a file the interpreter refused to load — and
    /// the marker is also the sentinel, so the block could not be stripped and
    /// re-saving compounded it.
    ///
    /// Python and R keep byte-identical output, so no existing script of
    /// theirs changes. Octave moved from `#` to `%` when this fact stopped
    /// being answered twice — both parse there, `%` is what the rest of the
    /// Octave corpus uses, and an existing `#` banner is still recognised
    /// because `allBannerComments` carries the legacy spelling unconditionally.
    static func rawScriptBannerComment(language: AssignmentLanguage) -> String {
        language.lineCommentPrefix + rawScriptBannerBody
    }

    /// Every spelling of the banner, for recognition rather than emission.
    ///
    /// Includes the legacy `#` form unconditionally, so a Lua or Racket script
    /// that already carries a broken block gets it stripped on the next save
    /// instead of accumulating a second one. That is the only recovery path
    /// those files have — the block cannot be removed by hand without also
    /// removing the instructor's own first line if they have already tried.
    private static var allBannerComments: [String] {
        var banners = AssignmentLanguage.allCases.map { $0.lineCommentPrefix + rawScriptBannerBody }
        banners.append("#" + rawScriptBannerBody)
        return banners
    }

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
        language: AssignmentLanguage
    ) -> String {
        let stripped = stripExistingBlock(originalBody)
        guard !variables.isEmpty else { return stripped }

        let decls = emit(variables, language: language)
        let banner = rawScriptBannerComment(language: language)

        // A line that must stay first keeps line 1, and the block goes under it.
        //
        // Two of these exist. A shebang is the familiar one. Racket's `#lang`
        // is the other, and it is a STRONGER constraint than the shebang: a
        // `#lang` line does not merely prefer to be first, it opens the module
        // whose body the declarations belong to. `(define …)` written above it
        // is a read error no comment placement can rescue — so for Racket this
        // branch is not a nicety, it is the only correct placement.
        if stripped.hasPrefix("#!") || stripped.hasPrefix("#lang") {
            let lines = stripped.split(
                separator: "\n",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            let prologue = String(lines.first ?? "")
            let rest = lines.count > 1 ? String(lines[1]) : ""
            return [
                prologue,
                banner,
                decls,
                "",
                rest,
            ].joined(separator: "\n")
        }
        return [
            banner,
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
        let banners = Set(allBannerComments)
        guard banners.contains(where: body.contains) else { return body }
        var lines =
            body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let startIdx = lines.firstIndex(where: { banners.contains($0) }) else {
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
                scriptExtension: (filename as NSString).pathExtension),
            supportsRawScriptInlining(language)
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
