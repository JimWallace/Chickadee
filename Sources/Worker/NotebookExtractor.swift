import Foundation

struct NotebookExtraction {
    let source: String
    let codeCellCount: Int
}

struct NotebookExtractor {
    func notebookJSONObject(from data: Data, filename: String) throws -> [String: Any] {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        guard let object = rawObject as? [String: Any] else {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        return object
    }

    func isNotebookJSONObject(_ notebook: [String: Any]) -> Bool {
        guard notebook["metadata"] != nil,
              notebook["nbformat"] != nil,
              notebook["cells"] is [[String: Any]] || notebook["cells"] is [Any] else {
            return false
        }
        return true
    }

    func extractPythonSource(from notebook: [String: Any], filename: String) throws -> NotebookExtraction {
        guard let cells = notebook["cells"] as? [[String: Any]] else {
            throw SubmissionNormalizationError.invalidPythonSubmission(filename)
        }

        var parts: [String] = []
        var codeCellCount = 0

        for (index, cell) in cells.enumerated() {
            guard cell["cell_type"] as? String == "code" else { continue }

            let rawSource: String
            if let sourceLines = cell["source"] as? [String] {
                rawSource = sourceLines.joined()
            } else if let sourceString = cell["source"] as? String {
                rawSource = sourceString
            } else {
                continue
            }

            let trimmedSource = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty else { continue }
            codeCellCount += 1
            parts.append("# --- cell \(index + 1) ---\n\(trimmedSource)")
        }

        guard !parts.isEmpty else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }

        return NotebookExtraction(
            source: "# Generated from \(filename)\n\n" + parts.joined(separator: "\n\n") + "\n",
            codeCellCount: codeCellCount
        )
    }
}
