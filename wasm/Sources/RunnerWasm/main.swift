import JavaScriptKit
import RunnerCore

// Embedded-Swift bridge over the pure RunnerCore extractor. Registers a single
// JS-callable global, marshalling cells in / result out via JavaScriptKit JS
// values — no Foundation, no BridgeJS (both incompatible with Embedded Swift).
//
// Exposed to JS as `globalThis.runnerExtractPython(cells, filename)`:
//   cells    — array of { cell_type: string, source: string }
//   filename — string
//   returns  — { executableModule, introspectableSource, codeCellCount }
//
// Built for wasm only via scripts/build-runner-wasm.sh (Embedded Swift SDK).
let runnerExtractPython = JSClosure { args in
    guard let cellsArray = args.first?.object else { return .undefined }
    let filename = args.count > 1 ? (args[1].string ?? "") : ""
    let count = Int(cellsArray.length.number ?? 0)

    var cells: [NotebookCell] = []
    var index = 0
    while index < count {
        if let cellObject = cellsArray[index].object {
            cells.append(
                NotebookCell(
                    cellType: cellObject.cell_type.string ?? "",
                    source: cellObject.source.string ?? ""))
        }
        index += 1
    }

    let extracted = extractPython(cells: cells, filename: filename)

    guard let objectConstructor = JSObject.global.Object.function else { return .undefined }
    let result = objectConstructor.new()
    result.executableModule = .string(extracted.executableModule)
    result.introspectableSource = .string(extracted.introspectableSource)
    result.codeCellCount = .number(Double(extracted.codeCellCount))
    return .object(result)
}

JSObject.global.runnerExtractPython = .object(runnerExtractPython)
