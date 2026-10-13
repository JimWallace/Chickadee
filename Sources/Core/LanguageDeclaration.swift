// Core/LanguageDeclaration.swift
//
// The author's answer to "what language is this assignment?".  The manifest
// stores it as two fields, `language` and `languageDeclared`, for the reason
// that `TestProperties.languageDeclared` documents: an old runner must still
// decode a new manifest.  This enum states the three real states, so a call
// site does not combine the two fields by hand.
// See docs/manifest-format-v2.md, D5, and docs/language-declaration.md.

/// The language declaration of an assignment.
public enum LanguageDeclaration: Equatable, Sendable {
    /// Nobody has answered the question.  The boundary that accepts such a
    /// manifest records a declaration at once.
    case undeclared
    /// The author declared that the assignment has no language: a suite of
    /// hand-written scripts.
    case noLanguage
    /// The author declared this language.
    case language(AssignmentLanguage)
}

extension TestProperties {
    /// The language declaration that the two stored fields hold.
    ///
    /// The flag decides whether the question has an answer.  A manifest with
    /// a `language` but without the flag is `.undeclared`, which is the rule
    /// that course-bundle import and `BackfillDeclaredLanguage` apply.  Use
    /// `AssignmentLanguage.resolve(manifest:)` to read the language itself.
    ///
    /// The setter writes both fields.  For `.undeclared` it writes nil to
    /// both, so a stored `false` flag becomes nil; every reader treats the two
    /// the same.  It does not change the submission or grading mode;
    /// `applyLanguageDeclaration` does that.
    public var languageDeclaration: LanguageDeclaration {
        get {
            guard languageDeclared == true else { return .undeclared }
            return language.map(LanguageDeclaration.language) ?? .noLanguage
        }
        set {
            switch newValue {
            case .undeclared:
                language = nil
                languageDeclared = nil
            case .noLanguage:
                language = nil
                languageDeclared = true
            case .language(let declared):
                language = declared
                languageDeclared = true
            }
        }
    }
}
