// APIServer/Helpers/NotebookContributionSlots.swift
//
// Contribution slots: the server-side bound on how much of a student's
// notebook counts as their contribution.
//
// WHY THIS IS SERVER-SIDE AND NOT AN EDITOR RULE. A collaborative assignment
// gives each student a fixed number of places to write (three cells, one test
// each). The obvious implementation is to stop the editor creating more cells,
// and that does not work: JupyterLite keeps the document in the student's own
// browser, and notebook mode deliberately keeps the upload form open beside the
// editor so an `.ipynb` edited offline can be handed in. Any rule that only
// holds inside the editor does not hold.
//
// So the bound is applied where every submission already passes through:
// `mergeNotebook` reassembles the submitted notebook server-side before it is
// stored. Extra cells are not PREVENTED, they are IGNORED — which needs no UI
// enforcement, and survives an offline-edited upload unchanged.
//
// The marker is Chickadee-owned CELL METADATA rather than a source comment.
// `NotebookSubstitution.fencedCellMetadataKey` already proves the mechanism:
// it stamps `chickadee_personalized` on cells it rewrites, explicitly preserves
// foreign cell metadata, and uses the mark to avoid clobbering student edits on
// re-substitution. Metadata also survives the one edit a first-line comment
// convention cannot — a student pressing return at the top of the cell.

import Core
import Foundation

enum NotebookContributionSlots {

    /// Metadata key marking a cell as one of an assignment's contribution
    /// slots. Present on the instructor's starter notebook to DECLARE the
    /// slots, and carried through the student's copy to identify what they
    /// wrote in them.
    ///
    /// The value is the slot's label (e.g. "1"), which is not interpreted
    /// here — ordering is document order, so the label is for the author and
    /// for display, not for sorting. Any non-empty string marks a slot.
    static let slotMetadataKey = "chickadee_slot"

    /// True when this cell carries a slot marker.
    static func isSlotCell(_ cell: [String: Any]) -> Bool {
        guard let metadata = cell["metadata"] as? [String: Any],
            let raw = metadata[slotMetadataKey]
        else { return false }
        if let text = raw as? String { return !text.isEmpty }
        // A number or bool is a legitimate way to write a slot label by hand;
        // only an explicitly empty string means "not a slot".
        return true
    }

    /// How many contribution slots an instructor notebook's raw bytes declare.
    ///
    /// The bytes overload exists for callers that hold a notebook rather than
    /// its parsed cells — the result-ingest path, which asks whether an
    /// assignment is a contribution assignment at all. Returns 0 for anything
    /// that does not parse as a notebook, which is the same answer as "declares
    /// no slots" and the answer that keeps an ordinary assignment unaffected.
    static func declaredSlotCount(inInstructorNotebook data: Data) -> Int {
        guard let cells = NotebookCellSources.cells(from: data) else { return 0 }
        return declaredSlotCount(inInstructorCells: cells)
    }

    /// How many contribution slots an instructor notebook declares.
    ///
    /// Zero means the assignment is an ordinary one, and every caller treats
    /// that as "apply no bound" — which is what keeps every existing
    /// assignment byte-identical through this path.
    static func declaredSlotCount(inInstructorCells cells: [[String: Any]]) -> Int {
        cells.filter(isSlotCell).count
    }

    /// The student's cells, reduced to what their contribution is allowed to
    /// be: the slot-marked cells in document order, capped at `limit`.
    ///
    /// Everything else the student wrote is dropped. That is the whole point —
    /// a bound that only counted slot cells while keeping the rest would let a
    /// student put fifty tests in one unmarked cell and bypass it entirely.
    ///
    /// The sharp edge, stated rather than hidden: a helper the student wrote
    /// OUTSIDE a slot goes too, and their test then fails at grading against a
    /// name that is no longer defined. The scaffold is what mitigates it — the
    /// slots are where the prompt says to write — and the alternative (keeping
    /// unmarked cells) reopens the bypass. Worth revisiting if a real offering
    /// shows students tripping over it.
    static func retainedStudentCells(
        _ cells: [[String: Any]], limit: Int
    ) -> [[String: Any]] {
        guard limit > 0 else { return cells }
        return Array(cells.filter(isSlotCell).prefix(limit))
    }
}
