// APIServer/Services/KernelImportGuard.swift
//
// The authoring chokepoint for KernelEnvironment: refuse to save a
// browser-graded script whose imports the grading kernel cannot satisfy.
//
// Every hand-authored script write goes through one of four call sites — the web
// create and update handlers, `PUT /suite`, and the MCP `author_script` tool —
// and all four call this immediately before the zip write, so the check cannot
// be bypassed by choosing a different authoring surface.
//
// Generated scripts (pattern families, notebook checks) are deliberately NOT
// checked. They are produced by renderers whose imports are fixed and known
// good, they never pass through these entry points, and rejecting one would
// leave an instructor unable to fix it — the fault would be in the renderer.

import Core
import Foundation
import Vapor

enum KernelImportGuard {

    /// A reference a browser-graded script makes that its grading kernel cannot
    /// satisfy.
    struct Unsatisfied: Equatable, Sendable {
        let name: String
        let line: Int
    }

    /// The language a script file is graded in, or nil when its extension means
    /// neither kernel runs it (a `.sh` suite, a data file).
    ///
    /// Deliberately extension-based rather than `RunnerCore.classifyScript`:
    /// this decides which *inventory* to check against, and the browser router
    /// makes the same extension-first decision when it picks a substrate.
    ///
    /// `.lua` is browser-gradable but returns nil, and that is the right
    /// answer rather than a gap: emscripten-forge ships no Lua library
    /// packages, so the `chickadee-lua` inventory is empty and there is nothing
    /// a `require` could be checked against. A guard with an empty inventory
    /// would reject every `require`, including the `require("test_runtime")`
    /// every Lua test opens with.
    static func language(forFile filename: String) -> AssignmentLanguage? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "py": return .python
        case "r": return .r
        default: return nil
        }
    }

    /// The unsatisfiable references in `source`, given what the setup supplies.
    static func unsatisfied(
        in source: String,
        environment: KernelEnvironment,
        localModules: Set<String>
    ) -> [Unsatisfied] {
        switch environment.language {
        case .python:
            return PythonImportScanner.topLevelImports(in: source)
                .filter { !environment.provides($0.module) && !localModules.contains($0.module) }
                .map { Unsatisfied(name: $0.module, line: $0.line) }
        case .r:
            return RLibraryScanner.referencedPackages(in: source)
                .filter { !environment.provides($0.package) && !localModules.contains($0.package) }
                .map { Unsatisfied(name: $0.package, line: $0.line) }
        case .cpp, .racket, .java:
            // Unreachable twice over for all three: `language(forFile:)` returns nil
            // for their extensions, and no inventory exists to load — a
            // kernel-less language has no fixed browser environment for
            // anything to be unsatisfiable against. Reporting nothing is the
            // direction this guard resolves ambiguity by design.
            //
            // Racket would decline anyway even with an inventory, for Lua's
            // reason: `require` there names collections that ship with the
            // distribution, so a guard built from a package list would reject
            // the standard library.
            return []
        case .lua:
            // Unreachable in practice — `language(forFile:)` returns nil for
            // `.lua`, so no caller builds a Lua environment to pass here. The
            // arm exists because the switch is exhaustive on purpose, and it
            // reports nothing because that is the only answer an EMPTY
            // inventory supports: emscripten-forge ships no Lua library
            // packages, so every `require` would look unsatisfiable, including
            // the `require("test_runtime")` that opens every generated test.
            //
            // Reporting nothing is also the direction this guard resolves
            // ambiguity by design: a false positive blocks an instructor from
            // saving with no self-service fix.
            return []
        case .octave:
            // Unreachable for the same reason as Lua — `language(forFile:)`
            // returns nil for `.m`, deliberately: Octave has no import
            // statement to scan (functions resolve implicitly through the load
            // path), and the one loadable construct, `pkg load`, could only
            // ever be refused because emscripten-forge carries no Octave Forge
            // packages and the chickadee-octave inventory is empty. Reporting
            // nothing keeps the guard's resolve-toward-silence rule.
            return []
        }
    }

    /// The name a bundled file is importable under, or nil when it is not an
    /// importable source file for `language`.
    ///
    /// R is `source()`d by path rather than imported by name, so a bundled `.R`
    /// helper is not a `library()` target — but accepting its stem costs nothing
    /// and removes a whole class of false positive if a course ever ships a
    /// package-shaped helper.
    static func localModuleName(forFile filename: String) -> String? {
        let base = (filename as NSString).lastPathComponent
        let stem: String
        if base.hasSuffix(".py") {
            stem = String(base.dropLast(3))
        } else if base.lowercased().hasSuffix(".r") {
            stem = String(base.dropLast(2))
        } else {
            return nil
        }
        guard let first = stem.first, first == "_" || first.isLetter else { return nil }
        return stem.allSatisfy { $0 == "_" || $0 == "." || $0.isLetter || $0.isNumber }
            ? stem : nil
    }

    /// The human-facing rejection message.
    static func message(
        for unsatisfied: [Unsatisfied], filename: String, language: AssignmentLanguage
    ) -> String {
        // Unreachable through `check` for a kernel-less language: with no
        // vendored kernel there is no fixed browser environment, so nothing
        // is ever unsatisfiable. Kept total so a direct caller gets a
        // truthful sentence rather than a crash.
        guard
            case .notebookKernel(let envFile, _, _, let failure, _) = language.editorSupport
        else {
            return "\(filename) is in a language with no browser grading environment."
        }
        let names = unsatisfied.map(\.name)
        let list = names.map { "`\($0)`" }.joined(separator: ", ")
        let plural = names.count == 1 ? "it" : "they"
        let locations = unsatisfied.map { "\($0.name) (line \($0.line))" }.joined(separator: ", ")
        return """
            \(filename) needs \(list), which the browser grading environment does not provide, \
            so \(plural) would fail with \(failure) for every student who submits — even though \
            validation passes, because validation is graded by the native worker on a full \
            installation. Found at: \(locations). Either avoid it, switch this assignment to \
            worker grading, or ask a maintainer to add the package to \
            Tools/jupyterlite/\(envFile) and re-vendor the kernel.
            """
    }

    /// Throws when `content` references something the browser grading kernel
    /// cannot provide. A no-op unless every condition holds, because outside
    /// them the fixed-environment constraint does not apply:
    ///
    ///   * the file is Python or R,
    ///   * that language's inventory loaded,
    ///   * and the assignment is browser-graded — worker grading runs a real
    ///     interpreter, where the same reference is fine.
    static func check(
        filename: String,
        content: String,
        setup: APITestSetup,
        environments: KernelEnvironments?
    ) throws {
        guard
            let language = language(forFile: filename),
            let environment = environments?[language],
            let manifest = setup.decodedManifest(),
            manifest.effectiveGradingMode == .browser
        else { return }

        // Anything else bundled in the setup is available at run time, and is
        // the likeliest false positive: a test that imports the support file
        // sitting beside it. Include the file being written, so a script that
        // refers to itself by name is not reported.
        var localModules = Set(
            listZipEntries(zipPath: setup.zipPath)
                .compactMap(Self.localModuleName(forFile:)))
        if let own = localModuleName(forFile: filename) { localModules.insert(own) }

        let missing = unsatisfied(
            in: content, environment: environment, localModules: localModules)
        guard !missing.isEmpty else { return }

        throw WebAssignmentError.invalidParameter(
            name: "content",
            reason: message(for: missing, filename: filename, language: language))
    }
}
