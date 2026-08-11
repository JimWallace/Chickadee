// APIServer/Utilities/AssignmentLanguageResolution.swift
//
// One server-side entry point for "what language is this assignment?", so no
// route, service or MCP tool has to remember which signals exist or in which
// order they win.

import Core
import Foundation

extension AssignmentLanguage {

    /// The language this assignment DECLARES.
    ///
    /// It no longer reads the starter notebook, and that is the change: this
    /// used to fall through to the kernelspec whenever the manifest said
    /// nothing, so "the author chose Python" and "we guessed from a notebook"
    /// were the same answer on every call. Declaration is a requirement now —
    /// every creation path answers the question and `BackfillDeclaredLanguage`
    /// answered it for everything older — so the manifest always has the
    /// author's answer, and nil means they said "no language" rather than
    /// "nobody asked".
    ///
    /// Kept as a named wrapper rather than inlining `manifest.language` at its
    /// twenty-odd call sites: "the assignment's language" is the question those
    /// sites are asking, and a single place to read it is what made removing
    /// the derivation a small change instead of a sweep.
    static func resolve(for setup: APITestSetup, manifest: TestProperties) -> AssignmentLanguage? {
        _ = setup
        return resolve(manifest: manifest)
    }
}
