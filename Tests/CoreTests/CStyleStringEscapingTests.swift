// Tests/CoreTests/CStyleStringEscapingTests.swift
//
// Pins each language preset of `CStyleStringEscaping` to the bytes the
// per-language escapers produced before they were unified. Generated scripts
// are content-addressed (`spec_hash`), so a drift here would re-key every
// runner cache entry and re-test every submission.

import Core
import Testing

@Suite struct CStyleStringEscapingTests {
    /// Backslash, quote and the three named control characters are spelled
    /// the same way by every preset.
    @Test(arguments: [
        CStyleStringEscaping.python, .r, .lua, .octave, .cpp, .java, .racket,
    ])
    func namedEscapesAreShared(preset: CStyleStringEscaping) {
        #expect(preset.escapedContents(of: #"a\b"c"#) == #"a\\b\"c"#)
        #expect(preset.escapedContents(of: "x\ny\rz\tw") == #"x\ny\rz\tw"#)
        #expect(preset.quotedLiteral("hi") == "\"hi\"")
    }

    /// Non-ASCII passes through untouched in every preset.
    @Test(arguments: [
        CStyleStringEscaping.python, .r, .lua, .octave, .cpp, .java, .racket,
    ])
    func nonASCIIPassesThrough(preset: CStyleStringEscaping) {
        #expect(preset.escapedContents(of: "héllo → 世界") == "héllo → 世界")
    }

    /// The one thing that differs per language: how an unnamed control
    /// character is spelled, and whether DEL counts as one.
    @Test(arguments: [
        (CStyleStringEscaping.python, #"\x1f"#, "\u{7F}"),
        (.r, #"\u001f"#, "\u{7F}"),
        (.lua, #"\031"#, #"\127"#),
        (.octave, #"\037"#, #"\177"#),
        (.cpp, #"\037"#, #"\177"#),
        (.java, #"\037"#, #"\177"#),
        (.racket, #"\u001F"#, #"\u007F"#),
    ])
    func controlCharacterForm(preset: CStyleStringEscaping, unitSeparator: String, delete: String) {
        #expect(preset.escapedContents(of: "\u{1F}") == unitSeparator)
        #expect(preset.escapedContents(of: "\u{7F}") == delete)
    }

    /// NUL is a control character in every preset, never a raw byte.
    @Test(arguments: [
        CStyleStringEscaping.python, .r, .lua, .octave, .cpp, .java, .racket,
    ])
    func nulIsAlwaysEscaped(preset: CStyleStringEscaping) {
        let escaped = preset.escapedContents(of: "\u{0}")
        #expect(escaped.hasPrefix("\\"))
        #expect(!escaped.unicodeScalars.contains("\u{0}"))
    }

    /// Java's rule: no backslash-u escape may ever be emitted, because javac
    /// decodes it in the lexer.
    @Test func javaNeverEmitsUnicodeEscape() {
        let sample = String((0..<0x20).map { Character(Unicode.Scalar(UInt8($0))) }) + "\u{7F}"
        #expect(!CStyleStringEscaping.java.escapedContents(of: sample).contains("\\u"))
    }
}
