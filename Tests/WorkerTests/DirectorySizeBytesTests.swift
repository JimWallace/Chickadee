import XCTest
import Foundation
@testable import chickadee_runner

final class DirectorySizeBytesTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-directorysize-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func test_emptyDirectoryReturnsZero() throws {
        XCTAssertEqual(directorySizeBytes(at: tempDir), 0)
    }

    func test_sumsAllRegularFiles() throws {
        try Data(count: 100).write(to: tempDir.appendingPathComponent("a.bin"))
        try Data(count: 250).write(to: tempDir.appendingPathComponent("b.bin"))
        XCTAssertEqual(directorySizeBytes(at: tempDir), 350)
    }

    func test_recursesIntoSubdirectories() throws {
        let sub = tempDir.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 64).write(to: tempDir.appendingPathComponent("top.bin"))
        try Data(count: 128).write(to: sub.appendingPathComponent("leaf.bin"))
        XCTAssertEqual(directorySizeBytes(at: tempDir), 192)
    }

    func test_skipsHiddenFiles() throws {
        try Data(count: 50).write(to: tempDir.appendingPathComponent("visible.bin"))
        try Data(count: 200).write(to: tempDir.appendingPathComponent(".hidden"))
        // .skipsHiddenFiles option in the enumerator means we ignore dotfiles.
        XCTAssertEqual(directorySizeBytes(at: tempDir), 50)
    }

    func test_returnsNilForMissingDirectory() {
        let nonexistent = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(directorySizeBytes(at: nonexistent))
    }
}
