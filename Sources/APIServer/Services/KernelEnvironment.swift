// APIServer/Services/KernelEnvironment.swift
//
// What a browser grading kernel can import, per language, and therefore which
// references an authoring write should be stopped on.
//
// Background. Browser grading runs a vendored xeus kernel whose package set is
// fixed when the kernel is built, and the editor's CSP is `connect-src 'self'`,
// so there is no runtime install escape hatch: a package that is not baked in is
// an unrecoverable failure at grade time.
//
// That failure does not surface during authoring, which is what makes it worth
// guarding. An instructor's validation run is enqueued as a `.validation`
// submission and graded by the NATIVE worker — real CPython, real Rscript, with
// whatever is installed there — so a test importing `scipy` or calling
// `library(dplyr)` validates green and then fails for the first student who
// submits.
//
// Both languages have the problem; R had it worse. Until v0.5.19 the R
// environment was bare `xeus-r`, meaning base R and nothing else, so *any*
// tidyverse call failed. The Python environment has always had numpy/pandas at
// least.
//
// Scope, deliberately narrow, and identical for both languages:
//
//   * **Browser-graded assignments only.** A worker-graded assignment never
//     touches these kernels, so the same reference is fine there.
//   * **Third-party names only.** Anything the setup itself provides, anything
//     the runner injects, and anything under a student-module name is out of
//     scope. Those are the false-positive sources, and a false positive blocks
//     an instructor from saving with no self-service fix — adding a package is a
//     maintainer change plus a re-vendor.
//
// The inventory is read from each env's `importable-modules.json`, generated
// from the vendored kernel's own tarballs by `scripts/derive-kernel-modules.py`.
// Reading the shipped bytes rather than the environment YAML is the whole point:
// the YAML states an intent that is only true after a re-vendor, and a check
// derived from intent would accept an import the shipped kernel cannot serve.

import Core
import Foundation
import Vapor

/// The importable inventory of one vendored xeus environment.
struct KernelEnvironment: Sendable {
    let language: AssignmentLanguage
    /// Names provided by the env's packages — Python: `numpy`, `PIL`, …;
    /// R: every directory under `lib/R/library`, which includes base R.
    let packageModules: Set<String>
    /// Python's standard library. Empty for R, where base packages are ordinary
    /// library directories and so already appear in `packageModules`.
    let stdlibModules: Set<String>

    /// Modules the Python grading runtime writes into the workspace: they exist
    /// at run time and in no package. `test_runtime` is the harness every
    /// generated test imports, `_ck_inputs` carries per-student personalization,
    /// `sitecustomize` is loaded by the interpreter itself.
    ///
    /// R has no equivalent: its runtime helpers are `source()`d rather than
    /// attached, so they never appear as a `library()` call to check.
    func provides(_ name: String) -> Bool {
        if packageModules.contains(name) || stdlibModules.contains(name) { return true }
        // Both sets live on AssignmentLanguage so a new language has to state
        // its own answer rather than inherit whichever branch a `== .python`
        // test dropped it into. R's are empty by fact, not omission — see the
        // property docs.
        if language.runnerProvidedModules.contains(name) { return true }
        return language.studentModulePrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - Loading

    private struct Manifest: Decodable {
        let modules: [String]
        let stdlibModules: [String]
    }

    enum LoadError: Error, CustomStringConvertible {
        case missing(path: String)

        var description: String {
            switch self {
            case .missing(let path):
                return """
                    No importable-modules.json at \(path). It is generated from the vendored \
                    kernel by scripts/derive-kernel-modules.py; re-run that after re-vendoring.
                    """
            }
        }
    }

    /// The vendored env directory name for a language.
    static func environmentName(for language: AssignmentLanguage) -> String {
        switch language {
        case .python: return "chickadee-python"
        case .r: return "chickadee-r"
        case .lua: return "chickadee-lua"
        case .octave: return "chickadee-octave"
        // No such env is ever vendored (editorSupport is .uploadOnly, no
        // kernel exists) — the name resolves to a path that does not exist,
        // so `load(publicDirectory:)`'s try? skips it, which is the correct
        // outcome: no inventory, no import guard, nothing to check.
        case .cpp: return "chickadee-cpp"
        // Same outcome as C++, different reason: no Scheme-family kernel
        // exists on the channel to vendor. Resolves to a path that is not
        // there, so no inventory loads and nothing is checked.
        case .racket: return "chickadee-racket"
        }
    }

    /// Loads one language's inventory from a public directory.
    static func load(
        publicDirectory: String, language: AssignmentLanguage
    ) throws -> KernelEnvironment {
        let path =
            URL(fileURLWithPath: publicDirectory)
            .appendingPathComponent(
                "jupyterlite/xeus/\(environmentName(for: language))/importable-modules.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LoadError.missing(path: path.path)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path))
        return KernelEnvironment(
            language: language,
            packageModules: Set(manifest.modules),
            stdlibModules: Set(manifest.stdlibModules))
    }
}

/// Every language's inventory, or as many as the checkout has.
///
/// Keyed by language rather than one stored property per language. The
/// field-per-language shape needed three coordinated edits to teach it a new
/// one — the struct, the subscript, and the loader — and only the subscript was
/// a compiler error, so the other two could be missed and the new language
/// would simply always have a nil inventory. That is the same "enumerated
/// rather than discovered, fails open" shape recorded in
/// docs/adding-a-xeus-kernel.md. Loading now iterates `allCases`.
struct KernelEnvironments: Sendable {
    private let byLanguage: [AssignmentLanguage: KernelEnvironment]

    init(byLanguage: [AssignmentLanguage: KernelEnvironment]) {
        self.byLanguage = byLanguage
    }

    subscript(language: AssignmentLanguage) -> KernelEnvironment? {
        byLanguage[language]
    }

    /// Loads every language, tolerating any being absent. A missing inventory
    /// disables the check for that language only — the correct degradation,
    /// since this is an early warning and refusing every authoring write
    /// because a build artifact is missing would be far worse than the gap it
    /// closes.
    static func load(publicDirectory: String) -> KernelEnvironments {
        var loaded: [AssignmentLanguage: KernelEnvironment] = [:]
        for language in AssignmentLanguage.allCases {
            if let env = try? KernelEnvironment.load(
                publicDirectory: publicDirectory, language: language)
            {
                loaded[language] = env
            }
        }
        return KernelEnvironments(byLanguage: loaded)
    }
}

// MARK: - Application storage

extension Application {
    private struct KernelEnvironmentsKey: StorageKey {
        typealias Value = KernelEnvironments
    }

    /// The browser grading environments' inventories, loaded once at boot.
    var kernelEnvironments: KernelEnvironments? {
        get { storage[KernelEnvironmentsKey.self] }
        set { storage[KernelEnvironmentsKey.self] = newValue }
    }
}
