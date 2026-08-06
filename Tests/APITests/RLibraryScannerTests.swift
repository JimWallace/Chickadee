// Tests/APITests/RLibraryScannerTests.swift
//
// Same asymmetric contract as the Python scanner's tests: a missed reference
// restores the status quo, a wrongly-reported one blocks an instructor from
// saving. The "must NOT report" cases are the ones worth growing.
//
// R adds a wrinkle Python does not have. `library("dplyr")` keeps its package
// name inside a string, so the scanner cannot simply blank all strings the way
// the Python one does — but prose like `"run library(dplyr) first"` in a hint
// must still not register. Those two requirements pull in opposite directions
// and are the point of several cases below.

import Foundation
import Testing

@testable import APIServer

@Suite struct RLibraryScannerTests {

    private func packages(_ source: String) -> [String] {
        RLibraryScanner.referencedPackages(in: source).map(\.package)
    }

    // MARK: - The forms that must be found

    @Test func findsLibraryAndRequireCalls() {
        #expect(packages("library(dplyr)") == ["dplyr"])
        #expect(packages("require(dplyr)") == ["dplyr"])
        #expect(packages("requireNamespace(\"dplyr\")") == ["dplyr"])
        #expect(packages("library(data.table)") == ["data.table"])
    }

    @Test func findsQuotedAndUnquotedForms() {
        #expect(packages("library(\"dplyr\")") == ["dplyr"])
        #expect(packages("library('dplyr')") == ["dplyr"])
        #expect(packages("library( dplyr )") == ["dplyr"])
    }

    /// `::` is not a conditional construct, so unlike `library()` it counts
    /// wherever it appears — which is overwhelmingly inside functions.
    @Test func findsQualifiedReferencesAnywhereIncludingInsideFunctions() {
        #expect(packages("x <- dplyr::filter(d, a > 1)") == ["dplyr"])
        #expect(packages("y <- stats:::internal()") == ["stats"])
        #expect(
            packages(
                """
                summarise <- function(d) {
                    dplyr::group_by(d, g)
                }
                """) == ["dplyr"])
    }

    @Test func reportsEachPackageOnceInFirstAppearanceOrder() {
        let found = RLibraryScanner.referencedPackages(
            in: """
                library(readr)
                library(dplyr)
                library(readr)
                """)
        #expect(found.map(\.package) == ["readr", "dplyr"])
        #expect(found.map(\.line) == [1, 2])
    }

    // MARK: - The cases that must NOT be reported

    /// The R half of "do not reject what is guarded": an attach inside a
    /// function or a conditional is indented, so the column-0 rule covers it.
    @Test func ignoresIndentedAttachCalls() {
        #expect(
            packages(
                """
                if (interactive()) {
                    library(ggplot2)
                }
                """
            ).isEmpty)
        #expect(
            packages(
                """
                setup <- function() {
                    library(ggplot2)
                }
                """
            ).isEmpty)
    }

    @Test func ignoresComments() {
        #expect(packages("# library(ggplot2)").isEmpty)
        #expect(packages("x <- 1  # dplyr::filter is faster").isEmpty)
    }

    /// Teaching prose mentions package calls constantly. A hint string is not a
    /// dependency, and this is the case the quoted-form support could most
    /// easily break.
    @Test func ignoresPackageCallsMentionedInsideStrings() {
        #expect(packages("msg <- \"run library(ggplot2) first\"").isEmpty)
        #expect(packages("hint <- \"use dplyr::filter to subset\"").isEmpty)
        #expect(packages("cat(\"library(tidyr) is not loaded\\n\")").isEmpty)
    }

    /// A `#` inside a string does not start a comment, so the rest of the line
    /// must still be scanned.
    @Test func aHashInsideAStringDoesNotHideTheRestOfTheLine() {
        #expect(packages("title <- \"# heading\"; library(dplyr)") == ["dplyr"])
    }

    @Test func ignoresWordsThatMerelyResembleACall() {
        #expect(packages("librarian <- 1").isEmpty)
        #expect(packages("required <- TRUE").isEmpty)
        #expect(packages("x <- 3").isEmpty)
    }

    /// Underscores are not legal in R package names. The scanner must report
    /// NOTHING rather than the truncated head — inventing a dependency on
    /// `test` because someone wrote `test_runtime` is the exact failure mode it
    /// is built to avoid.
    @Test func ignoresNamesThatArentLegalRPackages() {
        #expect(packages("library(test_runtime)").isEmpty)
        #expect(packages("library(student_solution)").isEmpty)
        #expect(packages("x <- my_helper::f()").isEmpty)
    }

    /// `::` needs a name on both sides; R's `:` sequence operator must not
    /// register.
    @Test func ignoresTheSequenceOperator() {
        #expect(packages("xs <- 1:10").isEmpty)
        #expect(packages("for (i in 1:n) print(i)").isEmpty)
    }

    @Test func emptyAndTrivialSourcesAreSilent() {
        #expect(packages("").isEmpty)
        #expect(packages("\n\n").isEmpty)
    }
}

@Suite struct RImportAvailabilityTests {

    private let environment = KernelEnvironment(
        language: .r,
        packageModules: ["base", "stats", "utils", "dplyr", "tibble"],
        stdlibModules: [])

    private func unsatisfied(_ source: String, local: Set<String> = []) -> [String] {
        KernelImportGuard.unsatisfied(
            in: source, environment: environment, localModules: local
        ).map(\.name)
    }

    @Test func flagsAPackageTheKernelDoesNotHave() {
        #expect(unsatisfied("library(ggplot2)") == ["ggplot2"])
        #expect(unsatisfied("x <- lubridate::ymd(\"2026-01-01\")") == ["lubridate"])
    }

    @Test func acceptsWhatTheKernelProvides() {
        #expect(unsatisfied("library(dplyr)\nlibrary(stats)\ny <- tibble::tibble(a = 1)").isEmpty)
    }

    /// Base R packages are ordinary library directories in the vendored env, so
    /// they need no special case — but a regression here would reject every
    /// script that attaches `stats`, so it is worth pinning.
    @Test func acceptsBaseRPackages() {
        #expect(unsatisfied("library(stats)").isEmpty)
        #expect(unsatisfied("library(utils)").isEmpty)
    }

    /// R has no runner-injected *library*: its helpers are `source()`d, so
    /// nothing analogous to Python's `test_runtime` import appears, and Python's
    /// allowlist must not quietly apply here. `sitecustomize` is used because it
    /// is the one name in that set shaped like a legal R package.
    @Test func theRunnerProvidedPythonModulesDoNotLeakIntoR() {
        #expect(unsatisfied("library(sitecustomize)") == ["sitecustomize"])
    }

    @Test func acceptsPackagesTheSetupItselfProvides() {
        #expect(unsatisfied("library(helpers)", local: ["helpers"]).isEmpty)
    }

    @Test func localModuleNamesCoverRFilesToo() {
        #expect(KernelImportGuard.localModuleName(forFile: "helpers.R") == "helpers")
        #expect(KernelImportGuard.localModuleName(forFile: "helpers.r") == "helpers")
        #expect(KernelImportGuard.localModuleName(forFile: "data.csv") == nil)
    }

    @Test func theMessageIsWordedForR() {
        let message = KernelImportGuard.message(
            for: [.init(name: "ggplot2", line: 2)], filename: "publictest_plot.R", language: .r)
        #expect(message.contains("publictest_plot.R"))
        #expect(message.contains("ggplot2"))
        #expect(message.contains("line 2"))
        #expect(message.contains("environment-r.yml"))
        #expect(message.contains("library()"))
    }

    @Test func theGuardPicksTheLanguageFromTheExtension() {
        #expect(KernelImportGuard.language(forFile: "t.py") == .python)
        #expect(KernelImportGuard.language(forFile: "t.R") == .r)
        #expect(KernelImportGuard.language(forFile: "t.r") == .r)
        #expect(KernelImportGuard.language(forFile: "t.sh") == nil)
        #expect(KernelImportGuard.language(forFile: "data.csv") == nil)
    }
}

/// The generated R index is what the check reads, so its accuracy is the
/// feature. Asserts against the real vendored bytes.
@Suite struct VendoredRKernelModuleIndexTests {

    private static var publicDirectory: String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Public").path
    }

    @Test func theVendoredRIndexDescribesTheRealEnvironment() throws {
        let environment = try KernelEnvironment.load(
            publicDirectory: Self.publicDirectory, language: .r)

        // Base R, which arrives as ordinary library directories rather than
        // through any stdlib notion.
        for package in ["base", "stats", "utils", "graphics", "grDevices", "methods"] {
            #expect(environment.provides(package), "base R package \(package) should be available")
        }
        // The data-science set the environment file declares.
        for package in ["dplyr", "tidyr", "readr", "stringr", "tibble", "purrr", "forcats"] {
            #expect(environment.provides(package), "declared package \(package) should be available")
        }
        // Held out deliberately for their attach cost — see environment-r.yml.
        // If one of these starts passing, that decision was reversed and the
        // per-test time limits need revisiting with it.
        for package in ["ggplot2", "lubridate"] {
            #expect(
                !environment.provides(package),
                """
                \(package) is in the vendored R env, but it was excluded on purpose: its first \
                library() call costs far more than the default 10s per-test limit. Re-check that \
                limit before keeping it.
                """)
        }
    }

    @Test func theRIndexCarriesNoPythonOnlyFields() throws {
        // R derives entirely from the tarballs, with no dependency on the
        // building interpreter — unlike Python, whose C-extension stdlib names
        // come from the host.
        let url = URL(fileURLWithPath: Self.publicDirectory)
            .appendingPathComponent("jupyterlite/xeus/chickadee-r/importable-modules.json")
        let json =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        #expect((json["stdlibModules"] as? [String])?.isEmpty == true)
        #expect(json["derivedOnPython"] is NSNull)
    }
}
