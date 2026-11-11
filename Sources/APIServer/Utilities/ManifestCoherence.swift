// APIServer/Utilities/ManifestCoherence.swift
//
// The manifest rules every authoring door enforces, spelled once (#1713).
// The zip upload, the three `setManifest*` edits and the MCP grading-mode
// tool used to restate them; a fifth rule now lands here and reaches every
// door at once.
//
// The declared assignment type adds two rules (docs/assignment-types.md):
// an Assignment is never browser-graded, and a Class activity carries an
// `activity` block. The type is a column, not a manifest field, so each door
// passes it in. Nil means the manifest has no assignment row yet (a draft or
// a bare setup upload), and then no type rule applies.

import Core

enum ManifestCoherence {
    /// Every rule `manifest` breaks for an assignment of `type`, as the
    /// sentence the doors show, in a fixed order. Empty for a coherent
    /// manifest.
    static func violations(for type: AssignmentType?, in manifest: TestProperties) -> [String] {
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
        // Only the native worker stages a classmate's submission; the browser
        // runner stages a bundled bot.
        if manifest.gradingMode == .browser, manifest.activity?.kind.opponentSource.opponentNeedsWorker == true {
            found.append(activityOpponentGradingConflictMessage)
        }
        // A language with no editor kernel is upload-only by construction.
        // Asked of `editorSupport`, never of one language's name.
        if let language = manifest.language, requiresUploadOnlySubmission(language),
            manifest.submissionMode != .uploadOnly
        {
            found.append(requiresUploadOnlyMessage(language))
        }
        // An activity that ranks or matches students needs every student on
        // the same data. One message per file, so an edit that adds a second
        // personal file is refused although the first one is inherited.
        if manifest.activity?.kind.comparesStudents == true {
            for spec in manifest.datasets where !spec.isShared {
                found.append(ActivityAuthoring.personalDataMessage(file: spec.file))
            }
        }
        found += typeViolations(in: manifest, type: type)
        return found
    }

    /// The rules the declared type adds. Browser grading is read as the
    /// effective mode, the one that decides where the tests run: a stored
    /// `browser` on an upload-only setup grades on the worker.
    static func typeViolations(in manifest: TestProperties, type: AssignmentType?) -> [String] {
        guard let type else { return [] }
        var found: [String] = []
        if !type.allowsBrowserGrading, manifest.effectiveGradingMode == .browser {
            found.append(assignmentBrowserGradingMessage)
        }
        if type.requiresActivity, manifest.activity == nil {
            found.append(classActivityRequiresActivityMessage)
        }
        return found
    }

    /// The first rule `manifest` breaks, or nil. The zip upload's check.
    static func violation(for type: AssignmentType?, in manifest: TestProperties) -> String? {
        violations(for: type, in: manifest).first
    }

    /// The first rule that `change` would break on the stored `manifest` and
    /// that the manifest does not break already, or nil. An edit is refused
    /// for the incoherence it introduces, never for one it inherits, so a
    /// legacy manifest can still be edited toward coherence. An undecodable
    /// manifest has no rules to break here; the edit's own decode reports it.
    static func violation(
        for type: AssignmentType?, introducedBy change: (inout TestProperties) -> Void, in manifest: String?
    ) -> String? {
        guard var props = manifest.flatMap(decodeManifest(fromJSON:)) else { return nil }
        let before = violations(for: type, in: props)
        change(&props)
        return violations(for: type, in: props).first { !before.contains($0) }
    }

    /// The first type rule that declaring `next` would break on the stored
    /// `manifest` and that the current type does not break already, or nil.
    /// The type change's check: Bug Hunt 1 (a Class activity with no
    /// activity) may still become an Assignment, but an Assignment cannot
    /// become a Class activity before it has an activity.
    static func violation(
        declaring next: AssignmentType, over current: AssignmentType?, in manifest: String?
    ) -> String? {
        guard let props = manifest.flatMap(decodeManifest(fromJSON:)) else { return nil }
        let before = typeViolations(in: props, type: current)
        return typeViolations(in: props, type: next).first { !before.contains($0) }
    }

    /// An Assignment refuses browser grading (docs/assignment-types.md,
    /// decision 1). One message for every door: the grading-mode edit, a
    /// language or submission-mode edit that would make it effective, the
    /// type change, the zip upload and a restore.
    static let assignmentBrowserGradingMessage =
        "An Assignment is graded by the native worker, because browser grading would deliver its "
        + "release and secret tests to every student. Keep worker grading, or change the type to Lab "
        + "first."

    /// A Class activity carries an `activity` block (decision 3).
    static let classActivityRequiresActivityMessage =
        "A Class activity needs an activity. Set one first, or change the type to Assignment or Lab "
        + "before removing it."
}

/// The type a copied assignment declares: `carried`, unless the copy's
/// manifest grades it in the browser while `carried` refuses browser grading
/// (an Assignment), when the copy declares what `AssignmentType.derivedDeclaration`
/// gives the manifest (a Lab). A clone and a bundle import call it, so neither
/// door creates an Assignment whose secret tests reach the browser.
///
/// The activity requirement is not applied here. A copy introduces no new
/// incoherence, so a Class activity with no activity (Bug Hunt 1 and 2 in
/// HLTH 230-W27) is copied as it is, as `violation(introducedBy:)` keeps an
/// inherited violation, and `check_assignment` reports it. A missing carried
/// type derives; an unreadable manifest reads as an Assignment.
func admissibleAssignmentType(_ carried: AssignmentType?, manifest: TestProperties?) -> AssignmentType {
    guard let manifest else { return carried ?? .assignment }
    guard let carried else { return AssignmentType.derivedDeclaration(manifest: manifest) }
    if !carried.allowsBrowserGrading, manifest.effectiveGradingMode == .browser {
        return AssignmentType.derivedDeclaration(manifest: manifest)
    }
    return carried
}
