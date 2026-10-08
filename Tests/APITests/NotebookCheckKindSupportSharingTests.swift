// The save-time notebook-check refusal and the Add Test menu read one support
// table (#2259, item 7).
//
// `validateKindSupport` used to encode the R, Lua and Octave support table a
// second time, with the language name and the hand-written extension typed as
// literals. It now asks `notebookCheckKindIsSupported`, the predicate the menu
// and `get_server_info` read. These tests check that the two answers agree for
// every kind, and that the refusal still names the same language and
// extension it named before.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookCheckKindSupportSharingTests {

    /// The name and hand-written extension each refusal used before the fold.
    private static let refusalWording: [AssignmentLanguage: (name: String, extension: String)] = [
        .r: ("R", ".R"),
        .lua: ("Lua", ".lua"),
        .octave: ("Octave", ".m"),
    ]

    /// The kind-support refusal for `kind` in `language`, or nil when the
    /// check passes that step. A check with no fields can fail a later,
    /// per-kind field check; that error is not a kind-support refusal.
    private func kindRefusal(
        _ kind: NotebookCheckKind, _ language: AssignmentLanguage
    ) -> AuthoringValidationError? {
        do {
            try validateNotebookChecks([NotebookCheck(id: "c1", kind: kind)], language: language)
            return nil
        } catch let error as AuthoringValidationError {
            if case .notebookCheckKindUnsupported = error { return error }
            return nil
        } catch {
            return nil
        }
    }

    @Test(arguments: [AssignmentLanguage.python, .r, .lua, .octave])
    func theSaveTimeRefusalMatchesTheSharedPredicate(language: AssignmentLanguage) {
        for kind in NotebookCheckKind.allCases {
            let refused = kindRefusal(kind, language) != nil
            #expect(
                refused == !notebookCheckKindIsSupported(kind, language: language),
                "\(kind.rawValue) on \(language.displayName)")
        }
    }

    @Test(arguments: [AssignmentLanguage.r, .lua, .octave])
    func theRefusalKeepsItsLanguageNameExtensionAndList(language: AssignmentLanguage) throws {
        let wording = try #require(Self.refusalWording[language])
        let supported = NotebookCheckKind.allCases
            .filter { notebookCheckKindIsSupported($0, language: language) }
            .map(\.rawValue).sorted()
        for kind in NotebookCheckKind.allCases where !notebookCheckKindIsSupported(kind, language: language) {
            let error = try #require(kindRefusal(kind, language))
            guard
                case .notebookCheckKindUnsupported(
                    _, _, let name, let supportedKinds, let handWrittenExtension) = error
            else {
                Issue.record("Unexpected refusal \(error)")
                continue
            }
            #expect(name == wording.name)
            #expect(handWrittenExtension == wording.extension)
            #expect(supportedKinds == supported)
        }
    }
}
