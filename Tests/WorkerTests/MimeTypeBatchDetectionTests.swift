// Tests/WorkerTests/MimeTypeBatchDetectionTests.swift
//
// The Python normalizer types a multi-file upload with one `file` run, not one
// per file. The batch must give every file the type the per-file call gives
// it, in the same order, or the classification of the upload changes.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(1))) struct MimeTypeBatchDetectionTests {

    @Test func theBatchGivesEachFileItsPerFileType() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-mime-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let contents: [(String, Data)] = [
            ("solution.py", Data("def f():\n    return 1\n".utf8)),
            ("data.json", Data(#"{"cells": []}"#.utf8)),
            ("empty.txt", Data()),
            ("picture.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 64))),
            ("name with spaces.py", Data("print('x')\n".utf8)),
            ("bytes.bin", Data([0x00, 0x01, 0x02, 0xFF])),
        ]
        var urls: [URL] = []
        for (name, data) in contents {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            urls.append(url)
        }

        let detector = MimeTypeDetector()
        let batched = await detector.detectMimeTypes(for: urls)
        var single: [String?] = []
        for url in urls {
            single.append(try await detector.detectMimeType(for: url))
        }

        #expect(batched.count == urls.count)
        #expect(batched.allSatisfy { $0 != nil }, "the batch typed no file: \(batched)")
        #expect(batched == single)
    }

    @Test func noFilesIsNoTypes() async {
        #expect(await MimeTypeDetector().detectMimeTypes(for: []).isEmpty)
    }
}
