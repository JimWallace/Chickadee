// Tests/CoreTests/NotebookFunctionScannerTests.swift
//
// Unit tests for NotebookFunctionScanner.

import Foundation
import Testing

@testable import Core

struct NotebookFunctionScannerTests {

    /// The Python function scan, as a flat `[NotebookFunctionInfo]`.
    ///
    /// These assertions used to call `scanNotebookForFunctions(_:)`, a public
    /// Python-only entry point with no way to be told a language and no
    /// production caller left — this suite was the only thing holding it alive.
    /// It is gone; the behaviour it covered (parameter capture, type hints,
    /// docstrings, shadowing) belongs to the scan that actually runs, so these
    /// tests exercise that one through this shim.
    private func scanFunctions(_ notebookData: Data) -> [NotebookFunctionInfo] {
        scanNotebookForSectionsAndFunctions(notebookData, parsing: .python).functions.map(\.info)
    }

    // MARK: - Helpers

    /// Builds a minimal .ipynb JSON with a single code cell.
    private func notebook(code: String) -> Data {
        let escaped =
            code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
            {
              "cells": [
                {
                  "cell_type": "code",
                  "metadata": {},
                  "source": "\(escaped)"
                }
              ],
              "metadata": {},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        return Data(json.utf8)
    }

    /// Builds a notebook with multiple code cells.
    private func notebook(cells: [String]) -> Data {
        let cellsJSON = cells.map { code -> String in
            let escaped =
                code
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
                {
                  "cell_type": "code",
                  "metadata": {},
                  "source": "\(escaped)"
                }
                """
        }.joined(separator: ",")
        let json = """
            {
              "cells": [\(cellsJSON)],
              "metadata": {},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        return Data(json.utf8)
    }

    // MARK: - Tests

    @Test func emptyNotebook() {
        let nb = Data(
            """
            {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """.utf8)
        #expect(scanFunctions(nb).isEmpty)
    }

    @Test func invalidJSON() {
        #expect(scanFunctions(Data("not json".utf8)).isEmpty)
    }

    @Test func singleSimpleFunction() {
        let nb = notebook(code: "def foo(a, b):\n    return a + b\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].name == "foo")
        #expect(fns[0].paramNames == ["a", "b"])
        #expect(!fns[0].hasTypeHints)
        #expect(!fns[0].hasDocstring)
    }

    @Test func functionWithTypeHints() {
        let nb = notebook(code: "def bar(x: int, y: str) -> bool:\n    return True\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].name == "bar")
        #expect(fns[0].paramNames == ["x", "y"])
        #expect(fns[0].hasTypeHints)
        // Per-parameter type capture for the type-aware coercion in the
        // family editor.
        #expect(fns[0].paramTypes == ["int", "str"])
        #expect(fns[0].returnType == "bool")
    }

    @Test func functionWithReturnTypeHintOnly() {
        let nb = notebook(code: "def baz(n) -> list:\n    return []\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].hasTypeHints)
        #expect(fns[0].paramTypes == [nil])
        #expect(fns[0].returnType == "list")
    }

    @Test func functionWithMixedAnnotations() {
        // Partial type hints: `a: int` and `b` untyped, default on `b`.
        let nb = notebook(code: "def mix(a: int, b = 5) -> float:\n    return float(a + b)\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["a", "b"])
        #expect(fns[0].paramTypes == ["int", nil])
        #expect(fns[0].returnType == "float")
    }

    @Test func functionWithDefaultKeepsType() {
        // `x: int = 0` — type must survive even when a default value is present.
        let nb = notebook(code: "def with_default(x: int = 0) -> int:\n    return x\n")
        let fns = scanFunctions(nb)
        #expect(fns[0].paramTypes == ["int"])
        #expect(fns[0].returnType == "int")
    }

    @Test func paramHasDefaultRecorded() {
        // v0.4.94: a parallel `paramHasDefault` array so the family editor
        // can mark defaulted columns as optional (empty cell ⇒ use Python
        // default at test time).
        let nb = notebook(code: "def check(dob: str, currentDate: str = \"20260301\") -> bool:\n    return True\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramHasDefault == [false, true])
        #expect(fns[0].paramTypes == ["str", "str"])
    }

    @Test func paramHasDefaultEmptyWhenNoParams() {
        let nb = notebook(code: "def nothing():\n    return 1\n")
        let fns = scanFunctions(nb)
        #expect(fns[0].paramHasDefault.isEmpty)
    }

    @Test func functionWithoutAnyAnnotations() {
        // Baseline: no hints at all → paramTypes is [nil] per name, returnType nil.
        let nb = notebook(code: "def plain(a, b):\n    return a + b\n")
        let fns = scanFunctions(nb)
        #expect(fns[0].paramTypes == [nil, nil])
        #expect(fns[0].returnType == nil)
        #expect(!fns[0].hasTypeHints)
    }

    @Test func functionWithDocstring() {
        let nb = notebook(code: "def greet(name):\n    \"\"\"Greet someone.\"\"\"\n    return 'Hi ' + name\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].hasDocstring)
    }

    @Test func privateFunctionExcluded() {
        let nb = notebook(code: "def _helper(x):\n    pass\ndef public_fn(x):\n    pass\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].name == "public_fn")
    }

    @Test func isShadowedDecodes() throws {
        let json = Data(
            """
            {
              "name": "tax",
              "paramNames": ["price"],
              "hasTypeHints": true,
              "hasDocstring": false,
              "isShadowed": true
            }
            """.utf8)
        let decoded = try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        #expect(decoded.isShadowed == true)
    }

    @Test func isShadowedDecodeRequiresField() {
        // v0.6.0 removed the `decodeIfPresent ?? false` fallback; missing
        // `isShadowed` is now a decode error rather than silently false.
        let json = Data(
            """
            {
              "name": "tax",
              "paramNames": ["price"],
              "hasTypeHints": true,
              "hasDocstring": false
            }
            """.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        }
    }

    @Test func shadowedFunctionMarked() {
        // Pedagogical notebooks often redefine a function to extend it.  Only
        // the LAST definition is callable at runtime; the scanner must mark
        // earlier ones as shadowed so the family editor can warn the
        // instructor away from targeting them.
        let nb = notebook(
            code:
                "def tax(price: float) -> float:\n    return price * 1.13\n"
                + "def tax(price: float, exempt: bool, extra: bool) -> float:\n    return price\n"
        )
        let fns = scanFunctions(nb)
        #expect(fns.count == 2)
        #expect(fns[0].name == "tax" && fns[0].isShadowed)
        #expect(fns[1].name == "tax" && !fns[1].isShadowed)
        // Each entry retains its own paramTypes / returnType for the editor.
        #expect(fns[0].paramTypes == ["float"])
        #expect(fns[1].paramTypes == ["float", "bool", "bool"])
    }

    @Test func selfAndClsExcluded() {
        let nb = notebook(code: "def method(self, x, y):\n    pass\n")
        // Top-level def with self — unusual but the scanner just strips self
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["x", "y"])
    }

    @Test func noParameters() {
        let nb = notebook(code: "def get_count():\n    return 0\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames.isEmpty)
    }

    @Test func varargsExcluded() {
        let nb = notebook(code: "def variadic(a, *args, **kwargs):\n    pass\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["a"])
    }

    @Test func defaultValueStripped() {
        let nb = notebook(code: "def increment(n, step=1):\n    return n + step\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["n", "step"])
    }

    @Test func multipleFunctionsInOneCell() {
        let nb = notebook(code: "def add(a, b):\n    return a + b\n\ndef subtract(a, b):\n    return a - b\n")
        let fns = scanFunctions(nb)
        #expect(fns.count == 2)
        #expect(fns[0].name == "add")
        #expect(fns[1].name == "subtract")
    }

    @Test func functionsAcrossMultipleCells() {
        let nb = notebook(cells: [
            "def foo(x):\n    return x\n",
            "x = 1  # not a function",
            "def bar(y):\n    return y\n",
        ])
        let fns = scanFunctions(nb)
        #expect(fns.count == 2)
        #expect(fns[0].name == "foo")
        #expect(fns[1].name == "bar")
    }

    @Test func indentedFunctionNotTopLevel() {
        // Class methods or nested functions — indented, not top-level.
        let nb = notebook(code: "class MyClass:\n    def method(self, x):\n        pass\n")
        let fns = scanFunctions(nb)
        #expect(fns.isEmpty, "Indented method should not be treated as top-level")
    }

    @Test func markdownCellIgnored() {
        let json = """
            {
              "cells": [
                {
                  "cell_type": "markdown",
                  "metadata": {},
                  "source": "def fake_function(x):\\n    pass"
                }
              ],
              "metadata": {},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        #expect(scanFunctions(Data(json.utf8)).isEmpty)
    }

    @Test func paramCount() {
        let nb = notebook(code: "def triple(a, b, c):\n    pass\n")
        let fns = scanFunctions(nb)
        #expect(fns.first?.paramCount == 3)
    }

    @Test func sourceAsArrayOfLines() {
        // JupyterLite stores source as an array of strings, one per line.
        let json = """
            {
              "cells": [
                {
                  "cell_type": "code",
                  "metadata": {},
                  "source": ["def greet(name):\\n", "    return 'hi'\\n"]
                }
              ],
              "metadata": {},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        let fns = scanFunctions(Data(json.utf8))
        #expect(fns.count == 1)
        #expect(fns[0].name == "greet")
    }

    // MARK: - scanNotebookForSectionsAndFunctions (v0.4.100)

    /// Builds a notebook where cells alternate between markdown and code.
    /// Each entry is either `("md", "## Section Title")` or `("code", source)`.
    private func sectionedNotebook(_ cells: [(String, String)]) -> Data {
        let cellsJSON = cells.map { kind, source -> String in
            let escaped =
                source
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
                {
                  "cell_type": "\(kind == "md" ? "markdown" : "code")",
                  "metadata": {},
                  "source": "\(escaped)"
                }
                """
        }.joined(separator: ",")
        return Data(
            """
            {
              "cells": [\(cellsJSON)],
              "metadata": {},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """.utf8)
    }

    @Test func sectionScanner_tagsFunctionsWithPreviousHeader() {
        let nb = sectionedNotebook([
            ("md", "## Warm Up"),
            ("code", "def foo(a):\n    return a\n"),
            ("md", "## Challenge"),
            ("code", "def bar(b):\n    return b\n\ndef baz(c):\n    return c\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, parsing: .python)
        #expect(r.sectionNames == ["Warm Up", "Challenge"])
        #expect(r.functions.map(\.info.name) == ["foo", "bar", "baz"])
        #expect(r.functions.map(\.sectionName) == ["Warm Up", "Challenge", "Challenge"])
    }

    @Test func sectionScanner_functionBeforeAnyHeaderHasNilSection() {
        let nb = sectionedNotebook([
            ("code", "def before_section():\n    pass\n"),
            ("md", "## Later Section"),
            ("code", "def after_section():\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, parsing: .python)
        #expect(r.sectionNames == ["Later Section"])
        #expect(r.functions.count == 2)
        #expect(r.functions[0].sectionName == nil)
        #expect(r.functions[1].sectionName == "Later Section")
    }

    @Test func sectionScanner_deduplicatesRepeatedHeaderNames() {
        let nb = sectionedNotebook([
            ("md", "## Shared"),
            ("code", "def a():\n    pass\n"),
            ("md", "## Shared"),  // same title used again later — dedupes
            ("code", "def b():\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, parsing: .python)
        #expect(r.sectionNames == ["Shared"])
        #expect(r.functions.map(\.sectionName) == ["Shared", "Shared"])
    }

    @Test func sectionScanner_ignoresHashOneAndHashThreePlusHeaders() {
        // Only `## ` (exactly two) creates a section — single `#` is the
        // document title, `###` is a subheading.  Keeps sections tied to
        // the "question-level" structure of the notebook.
        let nb = sectionedNotebook([
            ("md", "# Assignment Title"),
            ("code", "def ignored_top():\n    pass\n"),
            ("md", "### Sub Heading"),
            ("code", "def ignored_sub():\n    pass\n"),
            ("md", "## Real Section"),
            ("code", "def actual():\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, parsing: .python)
        #expect(r.sectionNames == ["Real Section"])
        // First two functions appear before any `## ` — no section.
        #expect(r.functions.map(\.sectionName) == [nil, nil, "Real Section"])
    }

    @Test func sectionScanner_matchesAssignment3Layout() {
        // Smoke-tests the user's Assignment 3 structure: three `## `
        // sections ("Warm Up: Patient Record", "Warm Up II: Calculating
        // Patient Age", "Challenge: Answering Questions with a Patient
        // Database") with functions scattered across all three.  The
        // scaffolder will turn this into one section per `##` header and
        // an exists test per detected function.
        let nb = sectionedNotebook([
            ("md", "# Assignment 3 — Electronic Health Records"),
            ("md", "## Warm Up: Patient Record as Dictionary"),
            ("code", "def mailingLabel(record):\n    pass\n\ndef bmi(record):\n    pass\n"),
            ("md", "## Warm Up II: Calculating Patient Age"),
            ("code", "def age(dob, currentDate=\"20260301\"):\n    pass\n"),
            ("md", "## Challenge: Answering Questions with a Patient Database"),
            ("code", "def countPatients(patients):\n    pass\n"),
            ("code", "def countAdults(patients):\n    pass\n"),
            ("code", "def findPatientsByDiagnosis(patients, diagnosis):\n    pass\n"),
            ("code", "def averageAge(patients):\n    pass\n"),
            ("code", "def countOverWeightPatients(patients):\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, parsing: .python)
        #expect(
            r.sectionNames == [
                "Warm Up: Patient Record as Dictionary",
                "Warm Up II: Calculating Patient Age",
                "Challenge: Answering Questions with a Patient Database",
            ])
        #expect(
            r.functions.map(\.info.name) == [
                "mailingLabel", "bmi", "age",
                "countPatients", "countAdults", "findPatientsByDiagnosis",
                "averageAge", "countOverWeightPatients",
            ])
        // Each function is tagged with its preceding `##` header.
        #expect(r.functions[0].sectionName == "Warm Up: Patient Record as Dictionary")
        #expect(r.functions[1].sectionName == "Warm Up: Patient Record as Dictionary")
        #expect(r.functions[2].sectionName == "Warm Up II: Calculating Patient Age")
        for i in 3...7 {
            #expect(r.functions[i].sectionName == "Challenge: Answering Questions with a Patient Database")
        }
    }

    // MARK: - Section names survive an unreadable language

    /// A `## ` header is markdown. The scanner not being able to read a
    /// language's function definitions says nothing about its headers, and
    /// returning an empty `sectionNames` alongside the refusal denied suite
    /// -section scaffolding to five languages as collateral.
    @Test(arguments: [AssignmentLanguage.cpp, .racket])
    func sectionNamesAreReportedEvenWhenFunctionsCannotBeRead(_ language: AssignmentLanguage) {
        let nb = sectionedNotebook([
            ("md", "## Warm Up"),
            ("code", "f <- function(a) a\n"),
            ("md", "## Challenge"),
            ("code", "g <- function(b) b\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, language: language)
        #expect(r.sectionNames == ["Warm Up", "Challenge"])
        // The functions are still refused, with a reason — that half is
        // unchanged and is what `unsupportedReason` is for.
        #expect(r.functions.isEmpty)
        #expect(r.unsupportedReason?.isEmpty == false)
    }

    /// Python is unaffected: it reads both.
    @Test func pythonStillReportsBothHalves() {
        let nb = sectionedNotebook([
            ("md", "## Warm Up"),
            ("code", "def foo(a):\n    return a\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, language: .python)
        #expect(r.sectionNames == ["Warm Up"])
        #expect(r.functions.map(\.info.name) == ["foo"])
        #expect(r.unsupportedReason == nil)
    }

    // MARK: - Per-language definition parsers

    /// R: `name <- function(a, b = 2)`, plus the `=` spelling.
    @Test func rDefinitionsAreParsed() {
        let nb = sectionedNotebook([
            ("md", "## Warm Up"),
            ("code", "classify_bmi <- function(bmi, units = \"metric\") {\n  bmi\n}\n"),
            ("code", "second = function(x) x + 1\n"),
            ("code", "  indented <- function(x) x\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, language: .r)
        #expect(r.functions.map(\.info.name) == ["classify_bmi", "second"])
        let first = r.functions[0].info
        #expect(first.paramNames == ["bmi", "units"])
        #expect(first.paramHasDefault == [false, true])
        // R has no parameter annotations, so no types are claimed — the same
        // state an un-annotated Python function produces.
        #expect(first.paramTypes == [nil, nil])
        #expect(!first.hasTypeHints)
        #expect(r.functions[0].sectionName == "Warm Up")
    }

    /// Lua: all three definition forms. `local function` is the idiom, so
    /// missing it would miss most real definitions.
    @Test func luaDefinitionsAreParsedInAllThreeForms() {
        let nb = sectionedNotebook([
            ("code", "function plain(a, b)\nend\n"),
            ("code", "local function scoped(c)\nend\n"),
            ("code", "assigned = function(d)\nend\n"),
            // A method definition is not callable by bare identifier, so it is
            // deliberately not matched.
            ("code", "function M.method(e)\nend\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, language: .lua)
        #expect(r.functions.map(\.info.name) == ["plain", "scoped", "assigned"])
        #expect(r.functions[0].info.paramNames == ["a", "b"])
    }

    /// Octave: the return-variable forms are why it cannot share R's pattern —
    /// the function name is not the first identifier on the line.
    @Test func octaveDefinitionsAreParsedIncludingReturnVariables() {
        let nb = sectionedNotebook([
            ("code", "function bare(a)\nend\n"),
            ("code", "function y = single(b, c)\nend\n"),
            ("code", "function [y, z] = multiple(d)\nend\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb, language: .octave)
        #expect(r.functions.map(\.info.name) == ["bare", "single", "multiple"])
        #expect(r.functions[1].info.paramNames == ["b", "c"])
        #expect(r.functions[2].info.paramNames == ["d"])
    }

    /// A language's parser must not read another's syntax. An R notebook
    /// scanned as Lua should find nothing rather than something wrong.
    @Test func aParserDoesNotReadAnotherLanguagesSyntax() {
        let rSource = sectionedNotebook([("code", "f <- function(x) x\n")])
        #expect(scanNotebookForSectionsAndFunctions(rSource, language: .lua).functions.isEmpty)
        #expect(scanNotebookForSectionsAndFunctions(rSource, language: .python).functions.isEmpty)
        let pySource = sectionedNotebook([("code", "def f(x):\n    return x\n")])
        #expect(scanNotebookForSectionsAndFunctions(pySource, language: .r).functions.isEmpty)
    }

    /// Private names are excluded in every language, as they always were in
    /// Python — the traversal owns that rule, not the per-language parse.
    @Test func privateNamesAreExcludedInEveryLanguage() {
        let nb = sectionedNotebook([("code", "_hidden <- function(x) x\nshown <- function(y) y\n")])
        let r = scanNotebookForSectionsAndFunctions(nb, language: .r)
        #expect(r.functions.map(\.info.name) == ["shown"])
    }

    // MARK: - Parameter names the scanner must and must not accept

    /// Kills the `RelationalOperatorReplacement` on the identifier-start rule
    /// (`first.isLetter || first == "_"` becomes `|| first != "_"`).
    ///
    /// The flip is silent in both directions and both directions matter. A
    /// parameter actually named with a leading underscore stops being reported,
    /// so the family editor shows a signature one column short and every case
    /// row silently shifts its arguments left. A parameter starting with a
    /// digit — which no Python signature can contain, so its presence means the
    /// line was misparsed — starts being reported instead of rejected.
    @Test func parameterNamesMayStartWithAnUnderscoreButNotADigit() {
        let underscored = scanFunctions(notebook(code: "def f(_unused, x):\n    pass\n"))
        #expect(underscored.count == 1)
        #expect(underscored[0].paramNames == ["_unused", "x"])

        // A bare `_` is the conventional throwaway and is still a parameter.
        let bare = scanFunctions(notebook(code: "def g(_, y):\n    pass\n"))
        #expect(bare.count == 1)
        #expect(bare[0].paramNames == ["_", "y"])

        // Not an identifier: dropped, not reported.
        let digitLed = scanFunctions(notebook(code: "def h(1bad, ok):\n    pass\n"))
        #expect(digitLed.count == 1)
        #expect(digitLed[0].paramNames == ["ok"])
    }

    // MARK: - The decode path's length realignment

    /// `init(from:)` keeps a tolerance the memberwise init dropped in 0.5: a
    /// stored `paramTypes` / `paramHasDefault` whose length disagrees with
    /// `paramNames` is replaced by a correctly-sized neutral array rather than
    /// carried through. Every consumer indexes these arrays by parameter
    /// position, so a short one is an out-of-range crash and a long one silently
    /// mislabels columns.
    ///
    /// The 2026-08-19 sweep reported four survivors here — a relational flip and
    /// a swapped ternary on each of the two arrays — because nothing asserted the
    /// rule from either side. Under every one of them a *correct* wire payload is
    /// the one that gets discarded.
    @Test func alignedWireArraysSurviveDecoding() throws {
        let json = Data(
            """
            {
              "name": "bmi",
              "paramNames": ["mass", "height"],
              "paramTypes": ["float", null],
              "paramHasDefault": [false, true],
              "hasTypeHints": true,
              "hasDocstring": false,
              "isShadowed": false
            }
            """.utf8)
        let decoded = try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        #expect(decoded.paramTypes == ["float", nil])
        #expect(decoded.paramHasDefault == [false, true])
    }

    @Test func misalignedWireArraysAreReplacedNotCarried() throws {
        let json = Data(
            """
            {
              "name": "bmi",
              "paramNames": ["mass", "height"],
              "paramTypes": ["float"],
              "paramHasDefault": [true, false, true],
              "hasTypeHints": true,
              "hasDocstring": false,
              "isShadowed": false
            }
            """.utf8)
        let decoded = try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        #expect(decoded.paramTypes == [nil, nil])
        #expect(decoded.paramHasDefault == [false, false])
    }

    @Test func absentWireArraysAreSizedFromParamNames() throws {
        let json = Data(
            """
            {
              "name": "bmi",
              "paramNames": ["mass", "height"],
              "hasTypeHints": false,
              "hasDocstring": false,
              "isShadowed": false
            }
            """.utf8)
        let decoded = try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        #expect(decoded.paramTypes == [nil, nil])
        #expect(decoded.paramHasDefault == [false, false])
    }

}
