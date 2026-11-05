// APIServer/Utilities/PersonalizationPlaceholders.swift
//
// The per-student input names that an assignment's content refers to, and the
// names that it declares. `preview_personalization` audits one seed with the
// first; the `placeholders.unresolved` authoring check compares the two
// (#2747).

import Core
import Foundation

enum PersonalizationPlaceholders {
    /// Every input name the content refers to: `{{name}}` markers in the
    /// starter notebook, and `$name` refs (`argVarRefs` / `expectedVarRef`) in
    /// pattern-family cases, so the audit covers grading as well as the
    /// notebook.
    static func used(notebookData: Data?, manifest: TestProperties) -> Set<String> {
        var used = Set<String>()
        if let notebookData {
            used.formUnion(NotebookSubstitution.placeholderNames(in: notebookData))
        }
        for family in manifest.patternFamilies {
            for testCase in family.cases {
                for ref in testCase.argVarRefs.compactMap(\.self) { used.insert(ref) }
                if let expectedRef = testCase.expectedVarRef, !expectedRef.isEmpty {
                    used.insert(expectedRef)
                }
            }
        }
        return used
    }

    /// Every input name the manifest declares, global or in a section, literal
    /// or expression. A name resolves for some seed only if it is declared, so
    /// this answers "can it resolve at all" without evaluating anything.
    static func declared(in manifest: TestProperties) -> Set<String> {
        var names = Set(manifest.globalVariables.map(\.name))
        names.formUnion(manifest.globalExpressions.map(\.name))
        for section in manifest.sections {
            names.formUnion(section.variables.map(\.name))
            names.formUnion(section.expressions.map(\.name))
        }
        return names
    }
}
