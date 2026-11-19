// APIServer/Services/WorkingCopySeedSource.swift
//
// What a working copy is seeded from: the setup, the viewer, the seed bytes
// the page resolved (`workingCopySeed`) and the view. `workingCopySeedData`
// turns it into the notebook the editor would open now; the authoring draft
// (#2925) compares against exactly that.

import Foundation

struct WorkingCopySeedSource: Sendable {
    let setupID: String
    let userID: UUID
    let setup: APITestSetup
    /// The seed the page resolved, or nil for the viewer's latest submission
    /// (or the stored starter, in a template view).
    let defaultData: Data?
    let viewMode: NotebookViewMode
}
