// Tests/WorkerTests/NotebookExtractionPredicateTests.swift
//
// The three predicates inside RunnerCore's notebook extractor that decide what
// a top-level line IS: whether it declares something (safe to keep at module
// level) or executes something (quarantined), whether an assignment's
// right-hand side calls a function, and where a line's significant text starts
// and ends.
//
// The 2026-08-19 sweep (run 32265903112) reported seven surviving candidates
// across them. They sit in RunnerCore, which carries no APITests-skip caveat —
// its covering tests all run in the sweep — so these are the strongest kind of
// evidence the sweep produces: the suite really does run this code and really
// could not tell the difference.
//
// Each test names the mutation it kills. Every one was confirmed SURVIVED by
// `Tools/mutation/verify-survivor.py` against that run's record before it was
// written, and KILLED after.

import Foundation
import Testing

@testable import RunnerCore

@Suite struct NotebookExtractionPredicateTests {

    // MARK: isSafeTopLevelStatement — the quarantine decision

    /// Kills the SECOND `ChangeLogicalConnector` on the bare-string-literal
    /// check and the one on its continuation line.
    ///
    /// The guard reads `hasPrefix(""" ) || hasPrefix(''') || hasPrefix(") ||
    /// hasPrefix(')`, and the two mutants that survive turn it into `""" || '`
    /// and `""" || '''` respectively — each dropping one of the SINGLE-delimiter
    /// forms while keeping a triple. So the case that separates them is a plain
    /// one-delimiter string: a module-level `"a docstring"` or `'a docstring'`,
    /// which the mutants quarantine as if it executed something.
    ///
    /// Quarantining a docstring is not cosmetic — a quarantined top-level line
    /// is not kept in the introspectable source, so `inspect.getsource` and any
    /// `astStructure` check stop seeing it.
    @Test func plainStringLiteralsAreRecognisedAsSafeNotJustTripleQuoted() {
        // The triple-quoted forms (already covered, kept so the set is whole).
        #expect(isSafeTopLevelStatement(#""""a docstring""""#))
        #expect(isSafeTopLevelStatement("'''a docstring'''"))
        // The single-delimiter forms — the ones the survivors drop.
        #expect(isSafeTopLevelStatement(#""a docstring""#))
        #expect(isSafeTopLevelStatement("'a docstring'"))
    }

    /// Kills the `ChangeLogicalConnector` in `trimSpacesAndTabs`
    /// (`$0 == " " && $0 == "\t"`), which makes the predicate false for every
    /// character so nothing is trimmed at all.
    ///
    /// `isSafeTopLevelStatement` trims before testing its prefixes, so with the
    /// trim disabled an indented `def` no longer starts with `def ` and every
    /// indented declaration is quarantined.
    @Test func leadingIndentationIsTrimmedBeforeThePrefixTests() {
        #expect(isSafeTopLevelStatement("def f():"))
        #expect(isSafeTopLevelStatement("    def f():"))
        #expect(isSafeTopLevelStatement("\tclass C:"))
        #expect(isSafeTopLevelStatement("  import os"))
        // Trailing horizontal space must not defeat a match either.
        #expect(isSafeTopLevelStatement("import os  "))
    }

    /// A statement that executes is still quarantined — the predicate is only
    /// useful if it says no to something.
    @Test func executingStatementsAreNotSafe() {
        #expect(!isSafeTopLevelStatement("print('hi')"))
        #expect(!isSafeTopLevelStatement("x = compute()"))
    }

    // MARK: rhsContainsFunctionCall

    /// Kills the third and fourth `ChangeLogicalConnector` candidates on the
    /// identifier test — `prev.isNumber && prev == "_"` and
    /// `prev == "_" && prev == ")"`. Both make the underscore case impossible
    /// (nothing is both a digit and an underscore, or both an underscore and a
    /// close paren), and between them they also drop the digit and the
    /// close-paren cases.
    ///
    /// A false negative here means an assignment whose RHS calls a function is
    /// treated as a constant and kept at module level, so the call runs at
    /// import time — which is the thing the quarantine exists to prevent.
    @Test func anIdentifierEndingInADigitUnderscoreOrParenStillCounts() {
        // The plain letter case, already covered.
        #expect(rhsContainsFunctionCall("f(x)"))
        // A name ending in a digit — `prev.isNumber`.
        #expect(rhsContainsFunctionCall("load_v2(path)"))
        // A name ending in an underscore — the case both survivors make
        // unreachable.
        #expect(rhsContainsFunctionCall("private_(x)"))
        // A call on the result of a call — `prev == ")"`.
        #expect(rhsContainsFunctionCall("factory()(arg)"))
    }

    @Test func aParenNotPrecededByAnIdentifierIsNotACall() {
        #expect(!rhsContainsFunctionCall("(1 + 2) * 3"))
        #expect(!rhsContainsFunctionCall("[1, 2, 3]"))
        #expect(!rhsContainsFunctionCall("x + 1"))
    }

    // MARK: trimWhitespaceAndNewlines, through the public extractor

    /// Kills the first `ChangeLogicalConnector` in `trimWhitespaceAndNewlines`
    /// (`$0 == " " && $0 == "\t" || …`), which leaves newlines and carriage
    /// returns trimmed but spaces and tabs not.
    ///
    /// `extractPython` skips a cell whose trimmed source is empty. With the
    /// mutant a cell holding only spaces trims to itself, reads as non-empty,
    /// and is emitted — so the extracted module gains a cell boundary and a
    /// blank body, and `codeCellCount` counts a cell the author did not write.
    @Test func whitespaceOnlyCellsAreSkippedWhateverTheWhitespaceIs() {
        let cells = [
            NotebookCell(cellType: "code", source: "def f():\n    return 1"),
            NotebookCell(cellType: "code", source: "   "),
            NotebookCell(cellType: "code", source: "\t\t"),
            NotebookCell(cellType: "code", source: "\n\n"),
            NotebookCell(cellType: "code", source: " \t\n "),
        ]
        let extracted = extractPython(cells: cells, filename: "nb.ipynb")
        #expect(extracted.codeCellCount == 1, "only the one real cell should count")
    }
}
