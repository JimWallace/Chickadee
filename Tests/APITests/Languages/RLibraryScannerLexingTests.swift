// Tests/APITests/Languages/RLibraryScannerLexingTests.swift
//
// The comment and string rules of RLibraryScanner, one case per rule.
// RLibraryScannerTests covers the reference forms. Each case here puts a
// package reference AFTER a string, or a comment after one, on the same line,
// so a scanner that loses track of where the string ends gives a different
// answer.
//
// Found by a mutation run on the APIServer utilities (2026-11-13).

import Testing

@testable import APIServer

@Suite struct RLibraryScannerLexingTests {

    private func packages(_ source: String) -> [String] {
        RLibraryScanner.referencedPackages(in: source).map(\.package)
    }

    // MARK: - Comments after a string

    @Test func aCommentAfterAClosedStringIsStillAComment() {
        #expect(packages(#"x <- "ab"  # dplyr::filter is faster"#).isEmpty)
        #expect(packages("x <- 'ab'  # dplyr::filter is faster").isEmpty)
    }

    @Test func aHashInsideAStringThatEndsInAHashDoesNotStartAComment() {
        #expect(packages(#"msg <- "ok#"; library(dplyr)"#) == ["dplyr"])
    }

    @Test func aStringThatEndsInAnEscapedBackslashIsClosed() {
        #expect(packages(#"x <- "\\"; y <- dplyr::n()"#) == ["dplyr"])
        #expect(packages(#"x <- "\\"  # dplyr::filter"#).isEmpty)
    }

    @Test func anEscapedQuoteDoesNotCloseTheString() {
        #expect(packages(#"x <- "a\"b # c"; y <- dplyr::n()"#) == ["dplyr"])
    }

    // MARK: - Qualified references after a string

    @Test func aQualifiedReferenceAfterAClosedStringIsReported() {
        #expect(packages(#"y <- paste("a", dplyr::n())"#) == ["dplyr"])
        #expect(packages("y <- paste('a', dplyr::n())") == ["dplyr"])
    }

    @Test func aQualifiedReferenceAfterAStringWithAnEscapeIsReported() {
        #expect(packages(#"y <- paste("a\"b", dplyr::n())"#) == ["dplyr"])
    }

    @Test func aQualifiedReferenceInsideASingleQuotedStringIsNotReported() {
        #expect(packages("hint <- 'use dplyr::filter to subset'").isEmpty)
    }

    // MARK: - Column 0 after a string

    @Test func aLineThatStartsWithAStringIsAColumnZeroStatement() {
        // The column-0 test reads the line with its strings blanked, so the
        // blanking must keep the opening quote in place.
        #expect(packages(#""note"; library(dplyr)"#) == ["dplyr"])
        #expect(packages("'note'; library(dplyr)") == ["dplyr"])
    }

    // MARK: - Package names

    @Test func aPackageNameMayContainDigitsAndDots() {
        #expect(packages("library(R6)") == ["R6"])
        #expect(packages("x <- data.table::fread(f)") == ["data.table"])
    }
}
