// APIServer/Utilities/PersonalizedCellRestoration.swift
//
// Turns a *rendered* notebook back into the *template* it was rendered from,
// for the cells the server personalized.
//
// Every working copy handed to a viewer — students and staff alike — has its
// `{{name}}` placeholders replaced with that viewer's values, and each rewritten
// cell is tagged `metadata.chickadee_personalized` (NotebookSubstitution). That
// is right for reading and running, and wrong for authoring: writing an author's
// copy straight back would replace `patients = {{patients}}` in the assignment's
// notebook with one person's literal patient list, silently ending
// personalization for the whole class.
//
// So the save path (WebRoutes+NotebookSave) runs the incoming notebook through
// here first. Only tagged cells are touched, and each is restored from the
// canonical notebook's own text — never reconstructed — so this can add nothing
// the author did not already have. A tagged cell that cannot be matched to the
// canonical notebook is reported instead of guessed at: refusing a save is
// recoverable, quietly baking a student's values into the class template is not.
//
// An assignment with no personalization has no tagged cells, so the whole thing
// is one dictionary lookup and the input is returned untouched.

import Core
import Foundation

enum PersonalizedCellRestoration {

    /// The result of restoring one notebook.
    enum Outcome: Equatable {
        /// The notebook is safe to store: either it had no personalized cells,
        /// or every one of them was restored from the canonical notebook.
        case restored(Data)
        /// At least one personalized cell could not be matched to the canonical
        /// notebook; the names are the placeholders whose templates would have
        /// been lost. Nothing should be written.
        case unmatched(placeholders: [String])
    }

    /// Restores the `{{name}}` template text in every cell of `incoming` that
    /// carries the personalization tag, taking the text from `canonical` — the
    /// notebook currently stored for the assignment, which still holds the
    /// templates.
    ///
    /// Cells are matched by nbformat cell `id` first. When the incoming cell has
    /// no id (a notebook authored before nbformat 4.5), the canonical cell at
    /// the same index is accepted *only* if it is a code cell that actually
    /// carries the placeholders the tag names — a check strong enough that a
    /// coincidental index collision cannot pass it.
    static func restoreTemplates(in incoming: Data, canonical: Data?) -> Outcome {
        guard
            var notebook = JSONValue.object(from: incoming),
            var cells = notebook["cells"]?.arrayOfObjects
        else {
            // Not notebook-shaped: the caller has already rejected that, so
            // there is nothing here to restore.
            return .restored(incoming)
        }

        let taggedIndexes = cells.indices.filter { !taggedPlaceholders(in: cells[$0]).isEmpty }
        guard !taggedIndexes.isEmpty else { return .restored(incoming) }

        guard
            let canonical,
            let canonicalCells = NotebookCellSources.cells(from: canonical)
        else {
            // No stored template to restore from — every tagged cell is at risk.
            return .unmatched(
                placeholders: Set(taggedIndexes.flatMap { taggedPlaceholders(in: cells[$0]) }).sorted())
        }

        var canonicalByID: [String: [String: JSONValue]] = [:]
        for cell in canonicalCells {
            if let id = cell["id"]?.stringValue, !id.isEmpty {
                canonicalByID[id] = cell
            }
        }

        var unmatched = Set<String>()
        for index in taggedIndexes {
            let names = taggedPlaceholders(in: cells[index])
            guard
                let template = templateCell(
                    for: cells[index], at: index, names: names,
                    canonicalByID: canonicalByID, canonicalCells: canonicalCells)
            else {
                unmatched.formUnion(names)
                continue
            }
            cells[index] = restoring(cells[index], toSourceOf: template)
        }

        guard unmatched.isEmpty else { return .unmatched(placeholders: unmatched.sorted()) }

        notebook["cells"] = .array(cells.map(JSONValue.object))
        guard let encoded = JSONValue.data(fromObject: notebook) else {
            return .restored(incoming)
        }
        return .restored(encoded)
    }

    // MARK: - Private helpers

    /// The placeholder names a cell was personalized for, or `[]` when the cell
    /// carries no personalization tag.
    private static func taggedPlaceholders(in cell: [String: JSONValue]) -> [String] {
        guard let tag = cell["metadata"]?[NotebookSubstitution.fencedCellMetadataKey]?.stringValue else {
            return []
        }
        return tag.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// The canonical cell `cell` was rendered from: same id, or — for a notebook
    /// with no cell ids — the same position, provided that cell really is the
    /// template for `names`.
    private static func templateCell(
        for cell: [String: JSONValue],
        at index: Int,
        names: [String],
        canonicalByID: [String: [String: JSONValue]],
        canonicalCells: [[String: JSONValue]]
    ) -> [String: JSONValue]? {
        if let id = cell["id"]?.stringValue, !id.isEmpty {
            return canonicalByID[id]
        }
        guard canonicalCells.indices.contains(index) else { return nil }
        let candidate = canonicalCells[index]
        guard candidate["cell_type"]?.stringValue == "code" else { return nil }
        let carried = Set(NotebookSubstitution.placeholderNames(inSource: NotebookCellSources.cellSource(candidate)))
        guard carried.isSuperset(of: names) else { return nil }
        return candidate
    }

    /// `cell` with the template's source text and without the personalization
    /// tag — everything else the author changed (outputs, other metadata, cell
    /// type) is left exactly as they left it.
    private static func restoring(
        _ cell: [String: JSONValue], toSourceOf template: [String: JSONValue]
    ) -> [String: JSONValue] {
        var restored = cell
        restored["source"] = template["source"]
        if var metadata = restored["metadata"]?.objectValue {
            metadata.removeValue(forKey: NotebookSubstitution.fencedCellMetadataKey)
            restored["metadata"] = .object(metadata)
        }
        return restored
    }
}
