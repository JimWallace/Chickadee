// APIServer/Routes/Web/NotebookBootFacts.swift
//
// What the notebook editor's loading panel (`NotebookBootPanel`) takes from
// the assignment and the viewer: the language it names, and the bird it
// shows. Both notebook routes build their context through these.

import Core

enum NotebookBootFacts {
    /// The declared language's name when the editor has a kernel for it
    /// ("Python"). Nil for no declared language, for an upload-only one and
    /// for a manifest that does not decode: the panel then names "the
    /// kernel". Never inferred (docs/language-declaration.md), and never a
    /// failure, because this renders a page.
    static func kernelLanguage(manifestJSON: String) -> String? {
        guard let manifest = decodeManifest(fromJSON: manifestJSON),
            let language = AssignmentLanguage.resolve(manifest: manifest),
            case .notebookKernel = language.descriptor.editorSupport
        else { return nil }
        return language.displayName
    }

    /// The viewer's stored bird with the curious face, at the hero size (96px).
    /// Nil when they have no bird yet, which only staff can reach: a student's
    /// bird is drawn before a page renders. `isStaff` draws the staff ring.
    static func bird(avatarSpecJSON: String?, isStaff: Bool) -> AvatarPresentation? {
        guard var spec = avatarSpecJSON.flatMap(AvatarStore.decode) else { return nil }
        spec.expression = .curious
        return AvatarPresentation(for: spec, size: .hero, accessibility: .decorative, isStaff: isStaff)
    }
}
