// APIServer/Services/KernelPythonEnvironment.swift
//
// What the browser's Python grading environment can import, and therefore which
// imports an authoring write should be stopped on.
//
// Background. Browser grading used to run Pyodide, which resolved imports at run
// time from a ~363-package index; since #1271 it runs the vendored
// `chickadee-python` xeus kernel, whose package set is fixed when the kernel is
// built. The editor's CSP is `connect-src 'self'`, so there is no runtime
// install escape hatch: a package that is not baked in is an unrecoverable
// `ImportError`.
//
// That failure is worse than it looks, because it does not surface during
// authoring. An instructor's validation run is enqueued as a `.validation`
// submission and graded by the NATIVE worker, on a real CPython with whatever is
// installed there — so a test importing `scipy` validates green and then fails
// for the first student who submits. Checking at save time is what closes that
// gap, and it is a capability the Pyodide architecture never allowed: there was
// no fixed set to check against.
//
// Scope, deliberately narrow:
//
//   * **Browser-graded assignments only.** A worker-graded assignment never
//     touches this kernel — it runs real `python3` on the runner — so the same
//     import is perfectly fine there and must not be rejected.
//   * **Python only.** R has no equivalent gap to close here.
//   * **Third-party names only.** Anything the setup itself provides (a support
//     file, another test), anything the runner injects, and anything importable
//     under a student-module name is out of scope. Those are the false-positive
//     sources, and a false positive blocks an instructor from saving work with
//     no self-service fix — the env file is a maintainer-plus-re-vendor change.
//
// The available set is read from `importable-modules.json`, generated from the
// vendored kernel's own tarballs by `scripts/derive-kernel-modules.py`. Reading
// the shipped bytes rather than `environment-python.yml` is the whole point: the
// env file states an intent that is only true after a re-vendor, and re-vendors
// need micromamba plus network to repo.prefix.dev, so CI can never do one. A
// check derived from intent would accept `import scipy` while the shipped kernel
// has none.

import Foundation
import Vapor

/// The module inventory of a vendored xeus Python environment.
struct KernelPythonEnvironment: Sendable {
    /// Top-level names provided by the env's packages (`numpy`, `PIL`, …).
    let packageModules: Set<String>
    /// Top-level names provided by the standard library.
    let stdlibModules: Set<String>

    /// Modules the grading runtime writes into the workspace, which exist at run
    /// time but appear in no package. `test_runtime` is the harness every
    /// generated test imports; `_ck_inputs` carries per-student personalization
    /// values; `sitecustomize` is loaded by the interpreter itself.
    static let runnerProvidedModules: Set<String> = [
        "test_runtime", "sitecustomize", "_ck_inputs",
    ]

    /// Prefixes for the extracted-submission modules. The concrete name depends
    /// on what a student uploads and is unknowable while authoring, so any name
    /// starting with one of these is treated as provided.
    static let studentModulePrefixes: [String] = ["student", "_ck_"]

    func provides(_ module: String) -> Bool {
        if packageModules.contains(module) || stdlibModules.contains(module) { return true }
        if Self.runnerProvidedModules.contains(module) { return true }
        return Self.studentModulePrefixes.contains { module.hasPrefix($0) }
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

    /// Loads the inventory for the `chickadee-python` env under a public
    /// directory (`Public/jupyterlite/xeus/chickadee-python/`).
    static func load(publicDirectory: String) throws -> KernelPythonEnvironment {
        let path =
            URL(fileURLWithPath: publicDirectory)
            .appendingPathComponent("jupyterlite/xeus/chickadee-python/importable-modules.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LoadError.missing(path: path.path)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path))
        return KernelPythonEnvironment(
            packageModules: Set(manifest.modules),
            stdlibModules: Set(manifest.stdlibModules))
    }
}

// MARK: - Application storage

extension Application {
    private struct KernelPythonEnvironmentKey: StorageKey {
        typealias Value = KernelPythonEnvironment
    }

    /// The browser grading environment's module inventory, loaded once at boot.
    ///
    /// Absent when the vendored kernel or its generated index is not present —
    /// a source checkout without the vendored bytes, say. The import check then
    /// does nothing, which is the correct degradation: it is an early-warning
    /// nicety, and refusing every authoring write because a build artifact is
    /// missing would be far worse than the gap it closes.
    var kernelPythonEnvironment: KernelPythonEnvironment? {
        get { storage[KernelPythonEnvironmentKey.self] }
        set { storage[KernelPythonEnvironmentKey.self] = newValue }
    }
}

// MARK: - The authoring check

enum PythonImportAvailability {

    /// An import a browser-graded Python script makes that the grading kernel
    /// cannot satisfy.
    struct Unsatisfied: Equatable, Sendable {
        let module: String
        let line: Int
    }

    /// The unsatisfiable imports in `source`, given the modules the setup itself
    /// supplies.
    ///
    /// - Parameters:
    ///   - source: the Python file being written.
    ///   - environment: the grading kernel's inventory.
    ///   - localModules: top-level names the test setup provides — every other
    ///     `.py` file in it, including the one being written.
    static func unsatisfiedImports(
        in source: String,
        environment: KernelPythonEnvironment,
        localModules: Set<String>
    ) -> [Unsatisfied] {
        PythonImportScanner.topLevelImports(in: source)
            .filter { !environment.provides($0.module) && !localModules.contains($0.module) }
            .map { Unsatisfied(module: $0.module, line: $0.line) }
    }

    /// The module name a bundled file is importable under, or nil when it is not
    /// an importable Python file.
    static func localModuleName(forFile filename: String) -> String? {
        let base = (filename as NSString).lastPathComponent
        guard base.hasSuffix(".py") else { return nil }
        let stem = String(base.dropLast(3))
        guard let first = stem.first, first == "_" || first.isLetter else { return nil }
        return stem.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } ? stem : nil
    }

    /// The human-facing rejection message.
    static func message(for unsatisfied: [Unsatisfied], filename: String) -> String {
        let names = unsatisfied.map(\.module)
        let list = names.map { "`\($0)`" }.joined(separator: ", ")
        let plural = names.count == 1 ? "it" : "they"
        let lines = unsatisfied.map { "\($0.module) (line \($0.line))" }.joined(separator: ", ")
        return """
            \(filename) imports \(list), which the browser grading environment does not provide, \
            so \(plural) would fail with an ImportError for every student who submits — even \
            though validation passes, because validation is graded by the native worker on a \
            full Python. Found at: \(lines). Either avoid the import, switch this assignment to \
            worker grading, or ask a maintainer to add the package to \
            Tools/jupyterlite/environment-python.yml and re-vendor the kernel.
            """
    }
}
