// Tests/APITests/Assignments/MultipartFileListDecodingTests.swift
//
// `MultipartFileList` decodes a form field that holds either many files or
// one bare file. Most browsers send a repeated field, which decodes as an
// array. Safari sends one selected file as a bare file. The coverage report
// showed no test for this type. The tests use JSON, which goes through the
// same single-value decode path as a multipart body.

import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MultipartFileListDecodingTests {

    private func file(_ name: String, _ text: String) -> File {
        File(data: ByteBuffer(string: text), filename: name)
    }

    private func names(_ list: MultipartFileList) -> [String] {
        list.files.map(\.filename)
    }

    private func texts(_ list: MultipartFileList) -> [String] {
        list.files.map { String(buffer: $0.data) }
    }

    @Test func anArrayOfFilesDecodesInOrder() throws {
        let data = try JSONEncoder().encode([file("a.sh", "one"), file("b.sh", "two")])
        let list = try JSONDecoder().decode(MultipartFileList.self, from: data)
        #expect(names(list) == ["a.sh", "b.sh"])
        #expect(texts(list) == ["one", "two"])
    }

    @Test func oneBareFileBecomesAOneElementList() throws {
        let data = try JSONEncoder().encode(file("only.sh", "body"))
        let list = try JSONDecoder().decode(MultipartFileList.self, from: data)
        #expect(names(list) == ["only.sh"])
        #expect(texts(list) == ["body"])
    }

    @Test func anEmptyArrayDecodesAsNoFiles() throws {
        let list = try JSONDecoder().decode(MultipartFileList.self, from: Data("[]".utf8))
        #expect(list.files.isEmpty)
    }

    /// A value that is neither shape is refused, not read as no files.
    @Test func aValueThatIsNotAFileIsRefused() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MultipartFileList.self, from: Data("42".utf8))
        }
    }

    /// The list encodes as an array, also when it came from one bare file, so
    /// a round trip gives the same files.
    @Test func encodingAlwaysWritesAnArray() throws {
        let single = try JSONDecoder().decode(
            MultipartFileList.self, from: JSONEncoder().encode(file("only.sh", "body")))
        let encoded = try JSONEncoder().encode(single)
        let asArray = try JSONDecoder().decode([File].self, from: encoded)
        #expect(asArray.map(\.filename) == ["only.sh"])
        let again = try JSONDecoder().decode(MultipartFileList.self, from: encoded)
        #expect(texts(again) == ["body"])
    }
}
