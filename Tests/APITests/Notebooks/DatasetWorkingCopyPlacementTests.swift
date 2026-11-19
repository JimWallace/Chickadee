import Foundation
import Testing

@testable import APIServer

/// `DatasetWorkingCopyPlacement` (docs/dataset-shared-delivery.md) moves a
/// student's dataset file between a link to the shared extraction and a real
/// file of their own. The safety rule: a real-file write never reaches the
/// shared copy through a link.
@Suite final class DatasetWorkingCopyPlacementTests {
    private let root: String
    private let shared: String
    private let student: String

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-dataset-placement-\(UUID().uuidString)")
            .path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/shared", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/student", withIntermediateDirectories: true)
        shared = root + "/shared/patients.csv"
        student = root + "/student/patients.csv"
        try "id\n1\n2\n3\n".write(toFile: shared, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("A real file written before shared delivery becomes a link")
    func realFileBecomesLink() throws {
        try "id\n1\n2\n3\n".write(toFile: student, atomically: true, encoding: .utf8)

        try DatasetWorkingCopyPlacement.link(student, to: shared)

        #expect(DatasetWorkingCopyPlacement.linkTarget(of: student) == shared)
        #expect(try read(student) == "id\n1\n2\n3\n")
    }

    @Test("A per-student write over a link replaces the link and leaves the shared copy alone")
    func writeOverLinkNeverReachesTheSharedCopy() throws {
        try DatasetWorkingCopyPlacement.link(student, to: shared)

        try DatasetWorkingCopyPlacement.write("id\n2\n", to: student)

        #expect(DatasetWorkingCopyPlacement.linkTarget(of: student) == nil)
        #expect(try read(student) == "id\n2\n")
        #expect(try read(shared) == "id\n1\n2\n3\n")
    }

    @Test("A link to somewhere else is retargeted")
    func linkElsewhereIsRetargeted() throws {
        let other = root + "/shared/old.csv"
        try "old\n".write(toFile: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: student, withDestinationPath: other)

        try DatasetWorkingCopyPlacement.link(student, to: shared)

        #expect(DatasetWorkingCopyPlacement.linkTarget(of: student) == shared)
        #expect(try read(other) == "old\n")
    }

    @Test("A dangling link is replaced")
    func danglingLinkIsReplaced() throws {
        try FileManager.default.createSymbolicLink(atPath: student, withDestinationPath: root + "/shared/gone.csv")

        try DatasetWorkingCopyPlacement.link(student, to: shared)

        #expect(try read(student) == "id\n1\n2\n3\n")
    }

    @Test("Linking twice is a no-op")
    func linkIsIdempotent() throws {
        try DatasetWorkingCopyPlacement.link(student, to: shared)
        try DatasetWorkingCopyPlacement.link(student, to: shared)

        #expect(DatasetWorkingCopyPlacement.linkTarget(of: student) == shared)
    }
}
