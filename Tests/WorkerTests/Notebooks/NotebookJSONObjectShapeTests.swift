import Core
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
        let notebook: [String: JSONValue] = [
            "metadata": .object([:]), "nbformat": .int(4),
            "cells": .array([.object(["cell_type": .string("code"), "source": .string("x = 1")])]),
        ]
        #expect(extractor.isNotebookJSONObject(notebook))
    }

    @Test func anEmptyCellListIsStillANotebook() {
        let notebook: [String: JSONValue] = ["metadata": .object([:]), "nbformat": .int(4), "cells": .array([])]
        #expect(extractor.isNotebookJSONObject(notebook))
    }

    @Test func cellsMustBeAnArray() {
        let notebook: [String: JSONValue] = ["metadata": .object([:]), "nbformat": .int(4), "cells": .string("none")]
        #expect(!extractor.isNotebookJSONObject(notebook))
    }

    @Test(arguments: ["metadata", "nbformat", "cells"])
    func eachTopLevelKeyIsRequired(_ missing: String) {
        var notebook: [String: JSONValue] = ["metadata": .object([:]), "nbformat": .int(4), "cells": .array([])]
        notebook[missing] = nil
        #expect(!extractor.isNotebookJSONObject(notebook))
    }
}
