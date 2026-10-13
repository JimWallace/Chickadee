// Tests/CoreTests/LanguageDeclarationTests.swift
//
// `TestProperties.languageDeclaration` reads and writes the two stored
// fields, `language` and `languageDeclared`.  These tests pin the mapping in
// both directions, including the state that has a language but no flag, and
// that the setter keeps the wire bytes of the two-field form.

import Foundation
import Testing

@testable import Core

@Suite struct LanguageDeclarationTests {

    @Test func noFieldsIsUndeclared() {
        let manifest = TestProperties(language: nil)
        #expect(manifest.languageDeclaration == .undeclared)
    }

    @Test func flagWithoutLanguageIsNoLanguage() {
        let manifest = TestProperties(language: nil, languageDeclared: true)
        #expect(manifest.languageDeclaration == .noLanguage)
    }

    @Test func flagWithLanguageIsThatLanguage() {
        let manifest = TestProperties(language: .r, languageDeclared: true)
        #expect(manifest.languageDeclaration == .language(.r))
    }

    /// Course-bundle import and the backfill treat this state as not yet
    /// answered, so the view does too.
    @Test func languageWithoutFlagIsUndeclared() {
        let manifest = TestProperties(language: .python)
        #expect(manifest.languageDeclaration == .undeclared)
    }

    @Test(arguments: [
        LanguageDeclaration.undeclared, .noLanguage, .language(.lua), .language(.java),
    ])
    func setterRoundTrips(_ declaration: LanguageDeclaration) {
        var manifest = TestProperties(language: .python, languageDeclared: true)
        manifest.languageDeclaration = declaration
        #expect(manifest.languageDeclaration == declaration)
    }

    @Test func setterWritesBothFields() {
        var manifest = TestProperties(language: .python, languageDeclared: true)

        manifest.languageDeclaration = .noLanguage
        #expect(manifest.language == nil)
        #expect(manifest.languageDeclared == true)

        manifest.languageDeclaration = .undeclared
        #expect(manifest.language == nil)
        #expect(manifest.languageDeclared == nil)

        manifest.languageDeclaration = .language(.octave)
        #expect(manifest.language == .octave)
        #expect(manifest.languageDeclared == true)
    }

    /// The wire form stays the two v1 keys, so an old runner decodes it.
    @Test func setterKeepsTheTwoKeyWireForm() throws {
        var manifest = TestProperties(language: nil)
        manifest.languageDeclaration = .language(.r)
        let json = try #require(
            String(data: try ManifestCodec.stableEncoder.encode(manifest), encoding: .utf8))
        #expect(json.contains(#""language":"r""#))
        #expect(json.contains(#""languageDeclared":true"#))
    }
}
