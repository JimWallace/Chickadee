import Foundation
import Testing

@testable import chickadee_runner

// `isNotebookJSONObject` is the shape check every uploaded `.ipynb` passes
// through before extraction. Its `cells` test read `is [[String: Any]] || is
// [Any]`, where the first disjunct can never change the answer — a 2026-09
// mutation survivor — so it is `is [Any]` now, and these pin what the check
// actually decides: the three keys, and that `cells` is an array.
@Suite struct NotebookJSONObjectShapeTests {
    private let extractor = NotebookExtractor()

    @Test func aWellFormedNotebookIsAccepted() {
        let notebook: [String: Any] = [
            "metadata": [String: Any](), "nbformat": 4,
            "cells": [["cell_type": "code", "source": "x = 1"]],
        ]
        #expect(extractor.isNotebookJSONObject(notebook))
    }

    @Test func anEmptyCellListIsStillANotebook() {
        let notebook: [String: Any] = ["metadata": [String: Any](), "nbformat": 4, "cells": [Any]()]
        #expect(extractor.isNotebookJSONObject(notebook))
    }

    @Test func cellsMustBeAnArray() {
        let notebook: [String: Any] = ["metadata": [String: Any](), "nbformat": 4, "cells": "none"]
        #expect(!extractor.isNotebookJSONObject(notebook))
    }

    @Test(arguments: ["metadata", "nbformat", "cells"])
    func eachTopLevelKeyIsRequired(_ missing: String) {
        var notebook: [String: Any] = ["metadata": [String: Any](), "nbformat": 4, "cells": [Any]()]
        notebook[missing] = nil
        #expect(!extractor.isNotebookJSONObject(notebook))
    }
}
