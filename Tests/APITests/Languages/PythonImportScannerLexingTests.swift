// Tests/APITests/Languages/PythonImportScannerLexingTests.swift
//
// The string and name rules of PythonImportScanner, one case per rule.
// PythonImportScannerTests covers the import forms. A string in those cases
// sits on a line that is not an import, so it cannot show whether the scanner
// blanks the string or reads it as code. Each case here puts an import BEHIND
// a string on the same line, or inside one, so the two outcomes differ.
//
// Found by a mutation run on the APIServer utilities (2026-11-13).

import Testing

@testable import APIServer

@Suite struct PythonImportScannerLexingTests {

    private func modules(_ source: String) -> [String] {
        PythonImportScanner.topLevelImports(in: source).map(\.module)
    }

    // MARK: - A string hides its contents

    @Test func anImportStatementInsideADoubleQuotedStringIsNotReported() {
        #expect(modules(#"hint = "first; import scipy as sp""#).isEmpty)
    }

    @Test func anImportStatementInsideASingleQuotedStringIsNotReported() {
        #expect(modules("hint = 'first; import scipy as sp'").isEmpty)
    }

    @Test func anEscapedQuoteDoesNotCloseTheString() {
        #expect(modules(#"hint = "say \"hi\"; import scipy as sp""#).isEmpty)
    }

    // MARK: - A closed string does not hide the code after it

    @Test func anImportAfterAClosedStringOnTheSameLineIsReported() {
        #expect(modules(#"print("x"); import scipy"#) == ["scipy"])
        #expect(modules("print('x'); import scipy") == ["scipy"])
    }

    @Test func anImportAfterAStringWithAnEscapeIsReported() {
        #expect(modules(#"print("a\"b"); import scipy"#) == ["scipy"])
    }

    @Test func anImportAfterAClosedSingleQuotedDocstringIsReported() {
        #expect(modules("'''doc'''; import scipy") == ["scipy"])
    }

    @Test func aSingleQuotedDocstringHidesTheLinesInsideIt() {
        #expect(
            modules(
                """
                '''
                import scipy
                '''
                import numpy
                """) == ["numpy"])
    }

    // MARK: - Module names

    @Test func aModuleNameMayStartWithAnUnderscore() {
        #expect(modules("import _private") == ["_private"])
        #expect(modules("from _private.sub import thing") == ["_private"])
    }

    @Test func aModuleNameThatStartsWithADigitIsNotReported() {
        #expect(modules("import 2fast").isEmpty)
    }

    @Test func aModuleNameMayContainDigitsAfterTheFirstCharacter() {
        #expect(modules("import h5py") == ["h5py"])
    }

    @Test func tabsSeparateTheKeywordAndTheName() {
        #expect(modules("import\tnumpy") == ["numpy"])
        #expect(modules("from\tscipy\timport stats") == ["scipy"])
    }
}
