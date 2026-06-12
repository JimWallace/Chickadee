// Tests/APITests/DiskUsageBreakdownTests.swift
//
// Unit coverage for the per-id disk-footprint helpers backing the admin
// Storage tab's per-assignment breakdown.  Submissions and test-setup
// archives are stored flat as "<id>.<ext>", and test setups carry extra
// "shared/<id>/" + "notebooks/<id>/" subtrees — these tests pin both
// behaviours.

import Foundation
import Testing

@testable import APIServer

@Suite struct DiskUsageBreakdownTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "chickadee-disk-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ byteCount: Int, to path: String) throws {
        try Data(repeating: 0, count: byteCount).write(to: URL(fileURLWithPath: path))
    }

    @Test func topLevelFileSizesBucketsByIdBeforeFirstDot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try write(100, to: dir + "sub_aaaa1111.zip")
        try write(50, to: dir + "sub_bbbb2222.ipynb")
        // A nested subdirectory's bytes must not be attributed to a top-level id.
        try FileManager.default.createDirectory(
            atPath: dir + "nested", withIntermediateDirectories: true)
        try write(999, to: dir + "nested/inner.txt")

        let sizes = topLevelFileSizesByID(inDirectory: dir)
        #expect(sizes["sub_aaaa1111"] == 100)
        #expect(sizes["sub_bbbb2222"] == 50)
        #expect(sizes["nested"] == nil)
    }

    @Test func testSetupSizesIncludeSharedAndNotebookSubtrees() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try write(100, to: dir + "setup_xxxx1111.zip")
        try write(20, to: dir + "setup_xxxx1111.ipynb")
        try FileManager.default.createDirectory(
            atPath: dir + "shared/setup_xxxx1111", withIntermediateDirectories: true)
        try write(7, to: dir + "shared/setup_xxxx1111/data.csv")
        try FileManager.default.createDirectory(
            atPath: dir + "notebooks/setup_xxxx1111", withIntermediateDirectories: true)
        try write(3, to: dir + "notebooks/setup_xxxx1111/solution.ipynb")

        let sizes = testSetupSizesByID(testSetupsDirectory: dir)
        #expect(sizes["setup_xxxx1111"] == 100 + 20 + 7 + 3)
    }

    @Test func missingDirectoryYieldsEmptyMap() throws {
        let sizes = topLevelFileSizesByID(inDirectory: NSTemporaryDirectory() + "does-not-exist-\(UUID().uuidString)/")
        #expect(sizes.isEmpty)
    }
}
