// Tests/APITests/AssignmentHelpersTestCase.swift
//
// Shared base class for the AssignmentHelpers test suite.  Subclasses
// focus on manifest/suite operations vs. utility/edit-suite helpers so
// XCTest --parallel can spread them across workers.

import Core
import Fluent
import Vapor
import XCTest

@testable import chickadee_server

class AssignmentHelpersTestCase: XCTestCase {

    struct DecodedReindexedSuiteConfigRow: Decodable {
        let index: Int
        let isTest: Bool
        let tier: String
        let order: Int?
        let dependsOn: [String]?
        let points: Int
        let displayName: String?
    }

    func makeFile(named name: String, contents: String) -> File {
        var buffer = ByteBufferAllocator().buffer(capacity: contents.utf8.count)
        buffer.writeString(contents)
        return File(data: buffer, filename: name)
    }

    func makeZip(at zipPath: String, entries: [(name: String, content: String)]) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assignment-helper-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in entries {
            let path = tempDir.appendingPathComponent(entry.name)
            let parent = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(entry.content.utf8).write(to: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", "-r", zipPath, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip should succeed")
    }

    func notebookData(language: String = "python", source: String) -> Data {
        let json = """
            {
              "cells": [
                {
                  "cell_type": "code",
                  "source": \(String(data: try! JSONEncoder().encode([source]), encoding: .utf8)!)
                }
              ],
              "metadata": {
                "kernelspec": {
                  "name": "\(language)",
                  "language": "\(language)"
                },
                "language_info": {
                  "name": "\(language)"
                }
              },
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        return Data(json.utf8)
    }
}
