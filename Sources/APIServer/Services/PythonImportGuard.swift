// APIServer/Services/PythonImportGuard.swift
//
// The authoring chokepoint for KernelPythonEnvironment: refuse to save a
// browser-graded Python script whose imports the grading kernel cannot satisfy.
//
// Every hand-authored script write goes through one of three call sites — the
// web create/update handlers and the MCP `author_script` tool — and all three
// call this immediately before the zip write, so the check cannot be bypassed by
// choosing a different authoring surface.
//
// Generated scripts (pattern families, notebook checks) are deliberately NOT
// checked here. They are produced by renderers whose imports are fixed and known
// good, they never pass through these entry points, and rejecting one would
// leave an instructor unable to fix it — the fault would be in the renderer.

import Core
import Foundation
import Vapor

enum PythonImportGuard {

    /// Throws when `content` imports something the browser grading kernel cannot
    /// provide. A no-op unless every condition below holds, because outside them
    /// the fixed-environment constraint simply does not apply:
    ///
    ///   * the kernel inventory loaded (absent in a checkout without the
    ///     vendored bytes),
    ///   * the file is Python,
    ///   * and the assignment is browser-graded — a worker-graded assignment
    ///     runs real `python3` on the runner, where these imports are fine.
    static func check(
        filename: String,
        content: String,
        setup: APITestSetup,
        environment: KernelPythonEnvironment?
    ) throws {
        guard let environment, filename.hasSuffix(".py") else { return }
        guard let manifest = setup.decodedManifest(), manifest.gradingMode == .browser else {
            return
        }

        // Anything else bundled in the setup is importable at run time, and is
        // the likeliest false positive: a test that imports the support file
        // sitting beside it. Include the file being written, so a script that
        // imports itself by name is not reported.
        var localModules = Set(
            listZipEntries(zipPath: setup.zipPath)
                .compactMap(PythonImportAvailability.localModuleName(forFile:)))
        if let own = PythonImportAvailability.localModuleName(forFile: filename) {
            localModules.insert(own)
        }

        let unsatisfied = PythonImportAvailability.unsatisfiedImports(
            in: content, environment: environment, localModules: localModules)
        guard !unsatisfied.isEmpty else { return }

        throw WebAssignmentError.invalidParameter(
            name: "content",
            reason: PythonImportAvailability.message(for: unsatisfied, filename: filename))
    }
}
