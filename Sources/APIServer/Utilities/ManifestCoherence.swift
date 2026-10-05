// APIServer/Utilities/ManifestCoherence.swift
//
// The manifest rules every authoring door enforces, spelled once (#1713).
// The zip upload, the three `setManifest*` edits and the MCP grading-mode
// tool used to restate them; a fifth rule now lands here and reaches every
// door at once.

import Core

enum ManifestCoherence {
    /// Every rule `manifest` breaks, as the sentence the doors show, in a
    /// fixed order. Empty for a coherent manifest.
    static func violations(in manifest: TestProperties) -> [String] {
        var found: [String] = []
        // An upload-only assignment has no notebook page to host the browser
        // runner.
        if manifest.submissionMode == .uploadOnly, manifest.gradingMode == .browser {
            found.append(uploadModeGradingConflictMessage)
        }
        // Browser grading ships the whole setup workspace into the student's
        // kernel, which is what a grader-only mark exists to prevent.
        if manifest.gradingMode == .browser, !manifest.graderOnlyFiles.isEmpty {
            found.append(graderOnlyGradingConflictMessage)
        }
        // Only the native worker stages an opponent.
        if manifest.gradingMode == .browser, manifest.activity?.stagesAnOpponent == true {
            found.append(activityOpponentGradingConflictMessage)
        }
        // A language with no editor kernel is upload-only by construction.
        // Asked of `editorSupport`, never of one language's name.
        if let language = manifest.language, requiresUploadOnlySubmission(language),
            manifest.submissionMode != .uploadOnly
        {
            found.append(requiresUploadOnlyMessage(language))
        }
        return found
    }

    /// The first rule `manifest` breaks, or nil. The zip upload's check.
    static func violation(in manifest: TestProperties) -> String? {
        violations(in: manifest).first
    }

    /// The first rule that `change` would break on the stored `manifest` and
    /// that the manifest does not break already, or nil. An edit is refused
    /// for the incoherence it introduces, never for one it inherits, so a
    /// legacy manifest can still be edited toward coherence. An undecodable
    /// manifest has no rules to break here; the edit's own decode reports it.
    static func violation(
        introducedBy change: (inout TestProperties) -> Void, in manifest: String?
    ) -> String? {
        guard var props = manifest.flatMap(decodeManifest(fromJSON:)) else { return nil }
        let before = violations(in: props)
        change(&props)
        return violations(in: props).first { !before.contains($0) }
    }
}
