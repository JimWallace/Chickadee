// APIServer/Helpers/ApplicationLeaf+Chickadee.swift
//
// The one Leaf configuration, shared by the server and the test app so the
// tests render under the same rules as production.

import Leaf
import Vapor

extension Application.Leaf {
    /// Points Leaf at `rootDirectory` with missing imports as errors.
    ///
    /// Leaf's default skips an `#import` that no template exports and renders
    /// nothing in its place, so a page that forgets its title or content slot
    /// serves an empty one with no error. Here the missing slot throws, and
    /// the page fails loudly instead.
    func useChickadeeConfiguration(rootDirectory: String) {
        configuration = .init(rootDirectory: rootDirectory, tagIndicator: "#", ignoreUnfoundImports: false)
    }
}
