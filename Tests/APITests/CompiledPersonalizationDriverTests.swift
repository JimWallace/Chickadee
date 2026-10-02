// Tests/APITests/CompiledPersonalizationDriverTests.swift
//
// The two compiled personalization drivers (C++ and Java), executed against
// one support directory twice (#1788). Each used to build in the support
// directory it ran in, so its own source and binary were listed as support
// files on the next evaluation: the C++ driver included an earlier copy of
// itself, the Java driver named its own source twice on the javac line, and
// both failed with exit 3. Both now build in the evaluator's private
// directory, and a leftover from before is ignored.
//
// Skipped, visibly, when the toolchain is absent. CI has g++ and javac on
// the image.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(3))) struct CompiledPersonalizationDriverTests {

    static let requiresGpp: ConditionTrait = .enabled("requires g++ on PATH") {
        await cachedToolIsAvailable("g++")
    }
    static let requiresJavac: ConditionTrait = .enabled("requires javac on PATH") {
        await cachedToolIsAvailable("javac")
    }

    /// A support directory holding `files`, plus the leftovers an evaluation
    /// before this fix left behind, which the lister must ignore.
    private static func supportDirectory(files: [String: String], leftovers: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-compiled-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in leftovers {
            try "this is not valid source\n".write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private static func evaluateTwice(
        language: AssignmentLanguage, expression: String, in dir: URL
    ) async throws -> [String?] {
        var answers: [String?] = []
        for _ in 0..<2 {
            let values = try await PersonalizationEvaluator.evaluate(
                seedHex: "00ff",
                staticVariables: [],
                expressions: [PersonalizationExpression(name: "v", expression: expression)],
                supportFilesDirectory: dir.path,
                language: language)
            answers.append(values["v"])
        }
        return answers
    }

    @Test(Self.requiresGpp) func cppEvaluatesTwiceAgainstOneSupportDirectory() async throws {
        let dir = try Self.supportDirectory(
            files: ["helper.hpp": "inline int twice(int x) { return 2 * x; }\n"],
            leftovers: [".ck_personalize_driver.cpp", ".ck_personalize_driver"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let answers = try await Self.evaluateTwice(language: .cpp, expression: "twice(21)", in: dir)
        #expect(answers == ["42", "42"])
        // The build left nothing beside the helper and the leftovers it ignored.
        let listing = try Set(FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(listing == ["helper.hpp", ".ck_personalize_driver.cpp", ".ck_personalize_driver"])
    }

    @Test(Self.requiresJavac) func javaEvaluatesTwiceAgainstOneSupportDirectory() async throws {
        let dir = try Self.supportDirectory(
            files: ["Helper.java": "public class Helper { public static int twice(int x) { return 2 * x; } }\n"],
            leftovers: ["CkPersonalizeDriver.java"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let answers = try await Self.evaluateTwice(language: .java, expression: "Helper.twice(21)", in: dir)
        #expect(answers == ["42", "42"])
        let listing = try Set(FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(listing == ["Helper.java", "CkPersonalizeDriver.java"])
    }
}
