// Tests for `NotebookOutputs.stripped`: what clearing a starter notebook's
// outputs removes, what it keeps, and that a clean notebook keeps its bytes.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookOutputsTests {

    private static let ranNotebook = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"xpython"}},"cells":[\
        {"cell_type":"markdown","metadata":{},"attachments":{"plot.png":{"image/png":"AAAA"}},"source":["Read me"]},\
        {"cell_type":"code","execution_count":3,"metadata":{"tags":["keep"],"execution":{"iopub.status.idle":"2026-11-01T00:00:00Z"}},\
        "outputs":[{"output_type":"stream","name":"stdout","text":["42\\n"]}],"source":["print(42)"]},\
        {"cell_type":"raw","metadata":{},"source":["raw text"]}]}
        """

    private func cells(_ data: Data) throws -> [[String: JSONValue]] {
        try #require(JSONValue.object(from: data)?["cells"]?.arrayOfObjects)
    }

    @Test func clearsOutputsExecutionCountAndTimingFromCodeCells() throws {
        let stripped = NotebookOutputs.stripped(Data(Self.ranNotebook.utf8))
        let code = try cells(stripped)[1]
        // The keys stay, empty: nbformat requires both on a code cell.
        #expect(code["outputs"] == .array([]))
        #expect(code["execution_count"] == .null)
        let metadata = try #require(code["metadata"]?.objectValue)
        #expect(metadata["execution"] == nil)
        #expect(metadata["tags"] == .array([.string("keep")]))
        #expect(code["source"] == .array([.string("print(42)")]))
    }

    @Test func leavesMarkdownAttachmentsRawCellsAndNotebookMetadataAlone() throws {
        let original = Data(Self.ranNotebook.utf8)
        let before = try cells(original)
        let after = try cells(NotebookOutputs.stripped(original))
        #expect(after[0] == before[0])
        #expect(after[2] == before[2])
        let metadata = JSONValue.object(from: NotebookOutputs.stripped(original))?["metadata"]
        #expect(metadata == .object(["kernelspec": .object(["name": .string("xpython")])]))
    }

    @Test func returnsACleanNotebookByteForByte() {
        // Formatting a round trip would change: key order and spacing.
        let clean = Data(
            """
            {"cells":[{"source":["x = 1"],"outputs":[],"metadata":{},"execution_count":null,"cell_type":"code"}],
              "nbformat":4,"nbformat_minor":5,"metadata":{}}
            """.utf8)
        #expect(NotebookOutputs.stripped(clean) == clean)
        #expect(
            NotebookOutputs.stripped(NotebookOutputs.stripped(Data(Self.ranNotebook.utf8)))
                == NotebookOutputs.stripped(Data(Self.ranNotebook.utf8)))
    }

    @Test func returnsBytesThatAreNotANotebookUnchanged() {
        let notJSON = Data("not a notebook".utf8)
        #expect(NotebookOutputs.stripped(notJSON) == notJSON)
        let noCells = Data(#"{"metadata":{}}"#.utf8)
        #expect(NotebookOutputs.stripped(noCells) == noCells)
    }

    @Test func aDraftThatWasOnlyRunIsTheSameDraftAsTheStoredStarter() {
        // The draft comparison and the stored-bytes clearing share one
        // definition of what running a cell adds.
        let ran = Data(Self.ranNotebook.utf8)
        #expect(sameDraftContent(ran, starterNotebookForStorage(ran)))
    }

    @Test func starterNotebookForStorageNormalizesAndClears() throws {
        let stored = starterNotebookForStorage(Data(Self.ranNotebook.utf8))
        #expect(try cells(stored)[1]["outputs"] == .array([]))
        let kernelspec = JSONValue.object(from: stored)?["metadata"]?.objectValue?["kernelspec"]?.objectValue
        #expect(kernelspec?["display_name"] != nil)
    }
}
