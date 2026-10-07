// Tests/APITests/AssignmentHelpersFixtures.swift
//
// Free-function helpers replacing AssignmentHelpersTestCase.  These are
// pure utility — no Application, no DB — so they don't need a
// `with*App` wrapper.  Used by AssignmentHelpersManifestTests and
// AssignmentHelpersUtilityTests after the migration to Swift Testing.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

struct AHDecodedReindexedSuiteConfigRow: Decodable {
    let index: Int
    let isTest: Bool
    let tier: String
    let order: Int?
    let dependsOn: [String]?
    let points: Int
    let displayName: String?
}

func ahMakeFile(named name: String, contents: String) -> File {
    var buffer = ByteBufferAllocator().buffer(capacity: contents.utf8.count)
    buffer.writeString(contents)
    return File(data: buffer, filename: name)
}

func ahMakeZip(at zipPath: String, entries: [(name: String, content: String)]) async throws {
    try await writeZipFixture(at: zipPath, entries: entries.map { ($0.name, $0.content) })
}

func ahNotebookData(language: String = "python", source: String) throws -> Data {
    let sourceJSON = try String(data: JSONEncoder().encode([source]), encoding: .utf8) ?? "[]"
    let json = """
        {
          "cells": [
            {
              "cell_type": "code",
              "source": \(sourceJSON)
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
