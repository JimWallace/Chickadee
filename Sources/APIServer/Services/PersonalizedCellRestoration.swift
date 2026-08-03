// APIServer/Services/PersonalizedCellRestoration.swift
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
            var notebook = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any],
            var cells = notebook["cells"] as? [[String: Any]]
        else {
            // Not notebook-shaped: the caller has already rejected that, so
            // there is nothing here to restore.
            return .restored(incoming)
        }

        let taggedIndexes = cells.indices.filter { !taggedPlaceholders(in: cells[$0]).isEmpty }
        guard !taggedIndexes.isEmpty else { return .restored(incoming) }

        guard
            let canonical,
            let canonicalNotebook = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any],
            let canonicalCells = canonicalNotebook["cells"] as? [[String: Any]]
        else {
            // No stored template to restore from — every tagged cell is at risk.
            return .unmatched(
                placeholders: Set(taggedIndexes.flatMap { taggedPlaceholders(in: cells[$0]) }).sorted())
        }

        var canonicalByID: [String: [String: Any]] = [:]
        for cell in canonicalCells {
            if let id = cell["id"] as? String, !id.isEmpty {
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

        notebook["cells"] = cells
        guard let encoded = try? JSONSerialization.data(withJSONObject: notebook) else {
            return .restored(incoming)
        }
        return .restored(encoded)
    }

    // MARK: - Private helpers

    /// The placeholder names a cell was personalized for, or `[]` when the cell
    /// carries no personalization tag.
    private static func taggedPlaceholders(in cell: [String: Any]) -> [String] {
        guard
            let metadata = cell["metadata"] as? [String: Any],
            let tag = metadata[NotebookSubstitution.fencedCellMetadataKey] as? String
        else {
            return []
        }
        return tag.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// The canonical cell `cell` was rendered from: same id, or — for a notebook
    /// with no cell ids — the same position, provided that cell really is the
    /// template for `names`.
    private static func templateCell(
        for cell: [String: Any],
        at index: Int,
        names: [String],
        canonicalByID: [String: [String: Any]],
        canonicalCells: [[String: Any]]
    ) -> [String: Any]? {
        if let id = cell["id"] as? String, !id.isEmpty {
            return canonicalByID[id]
        }
        guard canonicalCells.indices.contains(index) else { return nil }
        let candidate = canonicalCells[index]
        guard (candidate["cell_type"] as? String) == "code" else { return nil }
        let carried = Set(NotebookSubstitution.placeholderNames(inSource: cellSource(candidate)))
        guard carried.isSuperset(of: names) else { return nil }
        return candidate
    }

    /// `cell` with the template's source text and without the personalization
    /// tag — everything else the author changed (outputs, other metadata, cell
    /// type) is left exactly as they left it.
    private static func restoring(_ cell: [String: Any], toSourceOf template: [String: Any]) -> [String: Any] {
        var restored = cell
        restored["source"] = template["source"]
        if var metadata = restored["metadata"] as? [String: Any] {
            metadata.removeValue(forKey: NotebookSubstitution.fencedCellMetadataKey)
            restored["metadata"] = metadata
        }
        return restored
    }

    /// nbformat allows `source` to be a string or an array of strings.
    private static func cellSource(_ cell: [String: Any]) -> String {
        if let source = cell["source"] as? String { return source }
        if let source = cell["source"] as? [String] { return source.joined() }
        return ""
    }
}
