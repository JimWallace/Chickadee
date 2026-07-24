import Foundation
import Testing

@testable import APIServer

// Regression coverage for the R-submission grading bug: an in-browser editor can
// save an R (`xr`) notebook under the Pyodide kernel, dropping/overwriting the R
// kernelspec on the submitted notebook. `mergeNotebook` must adopt the
// instructor notebook's kernel so the worker extracts the submission to the
// right language (`.R`, not `.py`) — otherwise every R test errors with
// "No R submission file was found to grade."
@Suite struct MergeNotebookKernelspecTests {
    private let codeCell: [String: Any] = [
        "cell_type": "code", "metadata": [:], "execution_count": NSNull(), "outputs": [],
        "source": ["x <- 1\n"],
    ]

    private func notebook(kernel: String?, language: String?) -> Data {
        var meta: [String: Any] = [:]
        if let kernel {
            meta["kernelspec"] = [
                "name": kernel, "display_name": kernel, "language": language ?? kernel,
            ]
        }
        if let language {
            meta["language_info"] = ["name": language]
        }
        let obj: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": meta, "cells": [codeCell],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func metadata(of data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any]
        else { return nil }
        return dict["metadata"] as? [String: Any]
    }

    private func kernelName(of data: Data) -> String? {
        (metadata(of: data)?["kernelspec"] as? [String: Any])?["name"] as? String
    }

    private func languageName(of data: Data) -> String? {
        (metadata(of: data)?["language_info"] as? [String: Any])?["name"] as? String
    }

    @Test func rInstructorCorrectsPythonStudentKernel() {
        let merged = mergeNotebook(
            student: notebook(kernel: "python", language: "python"),
            instructor: notebook(kernel: "xr", language: "r"))
        #expect(kernelName(of: merged) == "xr")
        #expect(languageName(of: merged) == "r")
    }

    @Test func studentMissingKernelAdoptsInstructor() {
        let merged = mergeNotebook(
            student: notebook(kernel: nil, language: nil),
            instructor: notebook(kernel: "xr", language: "r"))
        #expect(kernelName(of: merged) == "xr")
        #expect(languageName(of: merged) == "r")
    }

    @Test func pythonAssignmentStaysPython() {
        let merged = mergeNotebook(
            student: notebook(kernel: "python", language: "python"),
            instructor: notebook(kernel: "python", language: "python"))
        #expect(kernelName(of: merged) == "python")
        #expect(languageName(of: merged) == "python")
    }
}
