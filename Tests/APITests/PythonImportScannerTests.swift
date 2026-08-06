// Tests/APITests/PythonImportScannerTests.swift
//
// The scanner's contract is asymmetric on purpose (see PythonImportScanner):
// missing an import restores the status quo, but reporting one that is not
// really required blocks an instructor from saving legitimate work. So the
// "must NOT report" cases below matter more than the "must report" ones, and
// they are the ones to keep adding to.

import Foundation
import Testing

@testable import APIServer

@Suite struct PythonImportScannerTests {

    private func modules(_ source: String) -> [String] {
        PythonImportScanner.topLevelImports(in: source).map(\.module)
    }

    // MARK: - The forms that must be found

    @Test func findsPlainAndDottedImports() {
        #expect(modules("import numpy") == ["numpy"])
        #expect(modules("import numpy.linalg") == ["numpy"])
        #expect(modules("import os, sys") == ["os", "sys"])
        #expect(modules("import numpy as np") == ["numpy"])
        #expect(modules("import numpy.linalg as la, pandas as pd") == ["numpy", "pandas"])
    }

    @Test func findsFromImports() {
        #expect(modules("from scipy import stats") == ["scipy"])
        #expect(modules("from scipy.stats import norm") == ["scipy"])
        #expect(modules("from test_runtime import passed, failed") == ["test_runtime"])
        #expect(modules("from scipy import (stats,") == ["scipy"])
    }

    @Test func findsSeveralStatementsOnOneLine() {
        #expect(modules("import os; import scipy") == ["os", "scipy"])
    }

    @Test func reportsEachModuleOnceInFirstAppearanceOrder() {
        let found = PythonImportScanner.topLevelImports(
            in: """
                import pandas
                import numpy
                import pandas
                """)
        #expect(found.map(\.module) == ["pandas", "numpy"])
        #expect(found.map(\.line) == [1, 2])
    }

    @Test func reportsTheLineTheImportIsOn() {
        let found = PythonImportScanner.topLevelImports(
            in: """
                # a comment

                import scipy
                """)
        #expect(found == [PythonImport(module: "scipy", line: 3)])
    }

    // MARK: - The cases that must NOT be reported

    /// The whole "do not reject what is guarded" requirement, which falls out of
    /// the column-0 rule rather than needing conditional analysis.
    @Test func ignoresGuardedAndFunctionLocalImports() {
        #expect(
            modules(
                """
                try:
                    import scipy
                except ImportError:
                    scipy = None
                """
            ).isEmpty)
        #expect(
            modules(
                """
                def helper():
                    import seaborn
                    return seaborn
                """
            ).isEmpty)
        #expect(
            modules(
                """
                if SLOW:
                    import sympy
                """
            ).isEmpty)
    }

    @Test func ignoresRelativeImports() {
        #expect(modules("from . import helpers").isEmpty)
        #expect(modules("from .helpers import thing").isEmpty)
        #expect(modules("from ..package import thing").isEmpty)
    }

    @Test func ignoresImportsInsideComments() {
        #expect(modules("# import scipy").isEmpty)
        #expect(modules("x = 1  # import scipy").isEmpty)
    }

    /// Teaching material quotes example code constantly, so a docstring showing
    /// an import must not register as a dependency.
    @Test func ignoresImportsInsideStrings() {
        #expect(
            modules(
                #"""
                """
                Example:
                    import scipy
                """
                import numpy
                """#) == ["numpy"])
        #expect(modules(#"hint = "import seaborn to plot""#).isEmpty)
        #expect(modules("hint = 'import seaborn'").isEmpty)
    }

    @Test func ignoresWordsThatMerelyStartWithAKeyword() {
        #expect(modules("imported = True").isEmpty)
        #expect(modules("importlib_metadata = 1").isEmpty)
        #expect(modules("fromage = 'cheese'").isEmpty)
    }

    @Test func handlesAnUnterminatedDocstringWithoutRunningAway() {
        // An unbalanced triple quote means everything after it is string, not
        // code. Reporting nothing is the safe reading.
        #expect(
            modules(
                #"""
                """
                import scipy
                """#
            ).isEmpty)
    }

    @Test func emptyAndTrivialSourcesAreSilent() {
        #expect(modules("").isEmpty)
        #expect(modules("\n\n").isEmpty)
        #expect(modules("x = 1").isEmpty)
    }
}

@Suite struct PythonImportAvailabilityTests {

    private let environment = KernelEnvironment(
        language: .python,
        packageModules: ["numpy", "pandas", "matplotlib", "PIL"],
        stdlibModules: ["os", "sys", "math", "json"])

    private func unsatisfied(_ source: String, local: Set<String> = []) -> [String] {
        KernelImportGuard.unsatisfied(
            in: source, environment: environment, localModules: local
        ).map(\.name)
    }

    @Test func flagsAPackageTheKernelDoesNotHave() {
        #expect(unsatisfied("import scipy") == ["scipy"])
        #expect(unsatisfied("from seaborn import lineplot") == ["seaborn"])
    }

    @Test func acceptsWhatTheKernelProvides() {
        #expect(unsatisfied("import numpy\nimport math\nfrom PIL import Image").isEmpty)
    }

    /// The runner writes these into the workspace; they exist at run time and in
    /// no package, and every generated test imports `test_runtime`.
    @Test func acceptsRunnerProvidedModules() {
        #expect(unsatisfied("from test_runtime import passed, failed").isEmpty)
        #expect(unsatisfied("import _ck_inputs").isEmpty)
        #expect(unsatisfied("import sitecustomize").isEmpty)
    }

    /// The submission's module name depends on what a student uploads and is
    /// unknowable while authoring.
    @Test func acceptsStudentModuleNames() {
        #expect(unsatisfied("import student_solution").isEmpty)
        #expect(unsatisfied("from student_module import classify").isEmpty)
    }

    /// A support file bundled in the same test setup is a legitimate import and
    /// is the likeliest false positive.
    @Test func acceptsModulesTheSetupItselfProvides() {
        #expect(unsatisfied("import helpers", local: ["helpers"]).isEmpty)
        #expect(unsatisfied("from genome_gen import make", local: ["genome_gen"]).isEmpty)
    }

    @Test func localModuleNamesComeFromPythonFilesOnly() {
        #expect(KernelImportGuard.localModuleName(forFile: "helpers.py") == "helpers")
        #expect(KernelImportGuard.localModuleName(forFile: "dir/helpers.py") == "helpers")
        #expect(KernelImportGuard.localModuleName(forFile: "data.csv") == nil)
        #expect(KernelImportGuard.localModuleName(forFile: "test-one.py") == nil)
        #expect(KernelImportGuard.localModuleName(forFile: "run.sh") == nil)
    }

    @Test func theMessageNamesTheModuleTheLineAndAWayForward() {
        let message = KernelImportGuard.message(
            for: [.init(name: "scipy", line: 3)], filename: "publictest_stats.py",
            language: .python)
        #expect(message.contains("publictest_stats.py"))
        #expect(message.contains("scipy"))
        #expect(message.contains("line 3"))
        #expect(message.contains("environment-python.yml"))
        #expect(message.contains("worker grading"))
    }
}

/// The generated index is what the check reads, so its accuracy is the feature.
/// These assert against the real vendored bytes rather than a fixture.
@Suite struct VendoredKernelModuleIndexTests {

    private static var publicDirectory: String {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Public").path
    }

    @Test func theVendoredIndexLoadsAndDescribesTheRealEnvironment() throws {
        let environment = try KernelEnvironment.load(publicDirectory: Self.publicDirectory, language: .python)

        // The env's whole reason for existing.
        for module in ["numpy", "pandas", "matplotlib", "PIL"] {
            #expect(environment.provides(module), "vendored kernel should provide \(module)")
        }
        // Stdlib, which is derived separately from the package tarballs.
        for module in ["os", "sys", "math", "json", "dataclasses", "itertools"] {
            #expect(environment.provides(module), "stdlib module \(module) should be available")
        }
        // Packages that have no emscripten-forge build at all, so no re-vendor
        // can make them appear. If one of these ever starts passing, the index
        // is being generated from the wrong source.
        for module in ["seaborn", "networkx", "plotly"] {
            #expect(!environment.provides(module), "\(module) has no build and cannot be present")
        }
        // Removed in v0.5.19 on measured import cost — sklearn 10.8s (over the
        // default per-test limit by itself) and sympy 5.9s — having been added
        // only to preserve Pyodide parity. Pinned so re-adding one is a
        // deliberate act that revisits that limit, not a quiet re-vendor.
        for module in ["sklearn", "sympy"] {
            #expect(
                !environment.provides(module),
                """
                \(module) is back in the vendored Python env; it was dropped for its import \
                cost against the 10s per-test limit, so re-check that limit first
                """)
        }
    }

    /// The index must be regenerated after a re-vendor. Comparing it against the
    /// env metadata that ships beside it catches the case where someone updates
    /// the kernel and forgets — which would leave the check enforcing a stale
    /// package set, either blocking a newly-added package or accepting a dropped
    /// one.
    @Test func theIndexMatchesTheVendoredEnvironmentMetadata() throws {
        let environment = try KernelEnvironment.load(publicDirectory: Self.publicDirectory, language: .python)
        let metaURL = URL(fileURLWithPath: Self.publicDirectory)
            .appendingPathComponent("jupyterlite/xeus/chickadee-python/empack_env_meta.json")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))
        let packages =
            ((meta as? [String: Any])?["packages"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        #expect(!packages.isEmpty, "vendored env metadata lists no packages")

        // Every package whose import name is its own name must be present. This
        // is a subset check on purpose — plenty of packages import under a
        // different name (`pillow` → `PIL`, `scikit-learn` → `sklearn`), and the
        // index derives those from the tarballs rather than a name table.
        for package in packages where package.allSatisfy({ $0.isLetter }) {
            guard ["numpy", "pandas", "matplotlib", "packaging", "pytz", "six"].contains(package)
            else { continue }
            #expect(
                environment.provides(package),
                """
                \(package) is in the vendored env metadata but not in importable-modules.json — \
                re-run scripts/derive-kernel-modules.py after re-vendoring the kernel.
                """)
        }
    }
}
