// Tests/APITests/CompiledDriverFixtures.swift
//
// What the C++, Java and Racket personalization-driver suites share (#1789):
// a scratch directory, the canonical runtimes, and the seed fold computed in
// Swift, so a test asserts the reduction itself and not only that two copies
// agree with each other.

import ChickadeeTestSupport
import Foundation

enum CompiledDriverFixtures {

    /// The canonical grading runtime `name` under Tools/runner-support.
    static func runtime(_ name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Tools/runner-support/\(name)"), encoding: .utf8)
    }

    /// A fresh directory holding `files`. The caller removes it.
    static func directory(_ prefix: String, files: [String: String] = [:]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    /// Seeds to compare: a realistic 64-hex-digit value, none, short values,
    /// and upper case, which the fold must read as the same digits.
    static let seeds = [String(repeating: "9f3c", count: 16), "", "ff", "0", "ABC123"]

    /// The documented fold: base-16 Horner over the hex digits, mod 2^31-1,
    /// skipping anything that is not a hex digit.
    static func hornerSeed(_ hex: String) -> Int {
        hex.reduce(0) { acc, character in
            guard let digit = character.hexDigitValue else { return acc }
            return (acc * 16 + digit) % 2_147_483_647
        }
    }
}
