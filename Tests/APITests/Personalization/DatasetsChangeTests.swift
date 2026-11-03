// Tests for `DatasetsChange`, the change that the web `PUT /datasets` routes
// and MCP `set_dataset` both pass to `applyDatasetsEdit` (#2771).

import Core
import Testing

@testable import APIServer

@Suite struct DatasetsChangeTests {
    private func spec(_ file: String, _ size: Int) -> DatasetSpec {
        DatasetSpec(file: file, kind: .rowSample, sampleSize: size)
    }

    @Test func replaceAllWritesTheWholeArray() {
        let change = DatasetsChange.replaceAll([spec("a.csv", 3)])
        #expect(change.applied(to: [spec("b.csv", 5)]) == [spec("a.csv", 3)])
        #expect(change.writtenSpecs == [spec("a.csv", 3)])
    }

    /// A one-file change keeps the other files, so a lost manifest race keeps
    /// another edit of a different file (#2019).
    @Test func replaceKeepsTheOtherFiles() {
        let change = DatasetsChange.replace(file: "a.csv", with: spec("a.csv", 7))
        let result = change.applied(to: [spec("a.csv", 3), spec("b.csv", 5)])
        #expect(result == [spec("b.csv", 5), spec("a.csv", 7)])
        #expect(change.writtenSpecs == [spec("a.csv", 7)])
    }

    @Test func removeDropsEverySpecForTheFile() {
        let change = DatasetsChange.replace(file: "a.csv", with: nil)
        let result = change.applied(to: [spec("a.csv", 3), spec("b.csv", 5), spec("a.csv", 4)])
        #expect(result == [spec("b.csv", 5)])
        #expect(change.writtenSpecs.isEmpty)
    }
}
