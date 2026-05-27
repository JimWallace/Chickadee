import Foundation
import JavaScriptKit
import RunnerCore

// JS-facing bridge over the pure RunnerCore extractor. Input/output cross the
// boundary as JSON strings so the contract is trivial to call from JS. The pure
// transform (RunnerCore) stays Foundation-free; only this thin wasm-only bridge
// uses Foundation for JSON.

private struct CellDTO: Codable {
    let cell_type: String
    let source: String
}

private struct ResultDTO: Codable {
    let executableModule: String
    let introspectableSource: String
    let codeCellCount: Int
}

/// Exported to JS as `extractPythonJSON(cellsJSON, filename)`.
/// `cellsJSON` is a JSON array of `{ "cell_type": "...", "source": "..." }`.
/// Returns a JSON object `{ executableModule, introspectableSource, codeCellCount }`.
@JS public func extractPythonJSON(cellsJSON: String, filename: String) -> String {
    let dtos: [CellDTO]
    do {
        dtos = try JSONDecoder().decode([CellDTO].self, from: Data(cellsJSON.utf8))
    } catch {
        return #"{"error":"failed to decode cells JSON"}"#
    }

    let cells = dtos.map { NotebookCell(cellType: $0.cell_type, source: $0.source) }
    let extracted = extractPython(cells: cells, filename: filename)

    let result = ResultDTO(
        executableModule: extracted.executableModule,
        introspectableSource: extracted.introspectableSource,
        codeCellCount: extracted.codeCellCount
    )
    guard let data = try? JSONEncoder().encode(result) else {
        return #"{"error":"failed to encode result"}"#
    }
    return String(decoding: data, as: UTF8.self)
}
