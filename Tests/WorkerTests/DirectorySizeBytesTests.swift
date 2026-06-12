import Foundation
import Testing

@testable import chickadee_runner

@Suite final class DirectorySizeBytesTests {

    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-directorysize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func emptyDirectoryReturnsZero() throws {
        #expect(directorySizeBytes(at: tempDir) == 0)
    }

    @Test func sumsAllRegularFiles() throws {
        try Data(count: 100).write(to: tempDir.appendingPathComponent("a.bin"))
        try Data(count: 250).write(to: tempDir.appendingPathComponent("b.bin"))
        #expect(directorySizeBytes(at: tempDir) == 350)
    }

    @Test func recursesIntoSubdirectories() throws {
        let sub = tempDir.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 64).write(to: tempDir.appendingPathComponent("top.bin"))
        try Data(count: 128).write(to: sub.appendingPathComponent("leaf.bin"))
        #expect(directorySizeBytes(at: tempDir) == 192)
    }

    @Test func skipsHiddenFiles() throws {
        try Data(count: 50).write(to: tempDir.appendingPathComponent("visible.bin"))
        try Data(count: 200).write(to: tempDir.appendingPathComponent(".hidden"))
        // .skipsHiddenFiles option in the enumerator means we ignore dotfiles.
        #expect(directorySizeBytes(at: tempDir) == 50)
    }

    @Test func returnsNilForMissingDirectory() {
        let nonexistent = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        #expect(directorySizeBytes(at: nonexistent) == nil)
    }
}
