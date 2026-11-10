// APIServer/Utilities/DatasetDeliveryNote.swift
//
// The note the Files panel shows under a dataset: whether every student's
// editor reads one shared copy or holds a copy of their own
// (docs/dataset-shared-delivery.md). Built here, once, so the server-rendered
// row and the panel's repaint after an edit (Public/support-files.js) show the
// same words.

import Core

enum DatasetDeliveryNote {
    /// The note for a dataset, or nil for a partition, whose own note already
    /// says each student is dealt a part.
    static func text(for mode: DatasetDeliveryMode, isPartition: Bool) -> String? {
        guard !isPartition else { return nil }
        switch mode {
        case .shared: return "One shared copy."
        case .perStudent: return "One copy per student."
        }
    }
}
