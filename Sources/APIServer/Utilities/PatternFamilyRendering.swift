// APIServer/Utilities/PatternFamilyRendering.swift
//
// The render phase of applyPatternFamilies (split out of
// PatternFamilyApplication.swift in the 0.5 cleanup): every family's case
// scripts and existence guard are rendered exactly once, plus the raw-script
// overlay writes. Rendered bytes are deterministic — filenames and the
// spec_hash header feed the runner's setup-cache key — so this file must
// never introduce ordering or formatting nondeterminism.

import Core
import Fluent
import Foundation
import Vapor

/// The rendered outputs of every pattern family, keyed by family id —
/// produced exactly once per apply so the zip write and the manifest rebuild
/// consume identical artifacts.
struct RenderedFamilyArtifacts {
    /// One rendered script per enabled case, in render order.
    let caseScripts: [String: [GeneratedScript]]
    /// The auto existence guard (function-calling kinds only; absent for
    /// `.variableEquality` / no-enabled-cases families).
    let guardScripts: [String: GeneratedScript]
}

/// Renders every family's case scripts and existence guard once.
func renderFamilyArtifacts(
    families: [PatternFamily],
    familySectionID: [String: String],
    sectionVarsByID: [String: [FamilyVariable]],
    globalVariables: [FamilyVariable],
    perStudentNames: Set<String>,
    language: AssignmentLanguage = .python
) -> RenderedFamilyArtifacts {
    var caseScripts: [String: [GeneratedScript]] = [:]
    var guardScripts: [String: GeneratedScript] = [:]
    for family in families {
        let sectionVariables = familySectionID[family.id].flatMap { sectionVarsByID[$0] } ?? []
        caseScripts[family.id] = renderPatternFamily(
            family, sectionVariables: sectionVariables, globalVariables: globalVariables,
            perStudentNames: perStudentNames, language: language)
        if let guardScript = existenceGuard(
            for: family, sectionVariables: sectionVariables, globalVariables: globalVariables,
            language: language)
        {
            guardScripts[family.id] = guardScript
        }
    }
    return RenderedFamilyArtifacts(caseScripts: caseScripts, guardScripts: guardScripts)
}

/// Slice 1: the re-inline of global + section variables into every raw
/// (non-generated) Python test script, as a map of zip writes.  Idempotent —
/// the prepender strips any existing Chickadee inputs block before adding
/// the new one, so unchanged scripts stay byte-identical and skip the zip
/// rewrite.  Raw scripts are identified from the authored items (`.script`
/// case) so the new authored sectionID applies, not whatever the old
/// manifest had.
func rawScriptOverlayWrites(
    items: [AuthoredSuiteItem],
    generatedFilenames: Set<String>,
    zipPath: String,
    globalVariables: [FamilyVariable],
    sectionVarsByID: [String: [FamilyVariable]]
) -> [String: String] {
    var writes: [String: String] = [:]
    for item in items {
        guard case .script(let s) = item else { continue }
        let filename = s.script
        // If this filename was just generated (e.g. instructor renamed a
        // raw script to clash with a family-generated name), the family
        // version wins — skip the raw-script overlay.
        guard !generatedFilenames.contains(filename) else { continue }
        // A raw script's extension names its language. Resolved through
        // `AssignmentLanguage(scriptExtension:)` — the same call the MCP
        // `author_script` and single-script save paths already used.
        //
        // This was a hand-written switch on `py` and `r` with `default: nil`,
        // written when those were the only two languages. Lua, Octave, Racket
        // and C++ fell to the default, so a hand-written test in any of them
        // silently received NO global or section variables through this path
        // while the other two paths delivered them — the same feature present
        // or absent depending on which button the instructor pressed.
        let scriptLanguage: AssignmentLanguage? = {
            guard
                let language = AssignmentLanguage(
                    scriptExtension: (filename as NSString).pathExtension),
                TestScriptVariablePrepender.supportsRawScriptInlining(language)
            else { return nil }
            return language
        }()
        let sectionVars = s.sectionID.flatMap { sectionVarsByID[$0] } ?? []
        if let provided = s.content {
            // Declarative content from the payload (the PUT /suite channel
            // for creating/updating a hand-written script). Write it
            // verbatim, re-inlining global + section variables for scripts
            // that have a literal syntax. Idempotent at the zip layer —
            // identical bytes are a no-op there.
            writes[filename] =
                scriptLanguage.map {
                    TestScriptVariablePrepender.prependToRawScript(
                        provided, variables: globalVariables + sectionVars, language: $0)
                } ?? provided
        } else if let scriptLanguage {
            // No content provided — preserve the existing file, re-inlining
            // the current global + section variables (idempotent prepend).
            guard
                let existing = readScriptFromZip(
                    zipPath: zipPath,
                    filename: filename)
            else { continue }
            let updated = TestScriptVariablePrepender.prependToRawScript(
                existing,
                variables: globalVariables + sectionVars,
                language: scriptLanguage
            )
            if updated != existing {
                writes[filename] = updated
            }
        }
        // (.sh and other extensions with no provided content: left untouched.)
    }
    return writes
}
