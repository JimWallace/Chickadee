// Tests/APITests/Infrastructure/WorkerSecretFailLoudlyTests.swift
//
// Pins #2776: an auto-generated runner secret is either strong and saved, or
// startup fails. A missing wordlist used to fall back to 30 words, and a
// failed save was swallowed, so a restart made a new secret and every runner
// then failed HMAC auth. A server that already has a saved secret must start
// as before, wordlist or not.

import Foundation
import Testing

@testable import APIServer

@Suite(.serialized)
struct WorkerSecretFailLoudlyTests {

    private func makeTempDir() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-secret-loud-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func writeFullWordlist(to path: String) throws {
        try (0..<2500).map { "\(10000 + $0) word\($0)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    @Test func missingWordlistFailsInsteadOfUsingAFallbackList() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/absent-words.txt"
        try await withTestEnvironment(["RUNNER_SHARED_SECRET": nil]) {
            #expect(throws: WorkerSecretError.wordlistTooShort(path: wordlistPath, wordCount: 0)) {
                try resolveStartupWorkerSecret(
                    cliWorkerSecret: nil, workerSecretFilePath: secretPath,
                    workerSecretWordlistPath: wordlistPath)
            }
            #expect(!FileManager.default.fileExists(atPath: secretPath))
        }
    }

    @Test func shortWordlistFails() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let wordlistPath = dir + "/words.txt"
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8)
        #expect(throws: WorkerSecretError.wordlistTooShort(path: wordlistPath, wordCount: 3)) {
            try randomWorkerPassphrase(workerSecretWordlistPath: wordlistPath)
        }
    }

    @Test func unsavableGeneratedSecretFailsStartup() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // The parent directory does not exist, so the file cannot be created.
        let secretPath = dir + "/missing-dir/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try writeFullWordlist(to: wordlistPath)
        try await withTestEnvironment(["RUNNER_SHARED_SECRET": nil]) {
            let error = #expect(throws: WorkerSecretError.self) {
                try resolveStartupWorkerSecret(
                    cliWorkerSecret: nil, workerSecretFilePath: secretPath,
                    workerSecretWordlistPath: wordlistPath)
            }
            if case .notPersisted(let path, _) = error {
                #expect(path == secretPath)
            } else {
                Issue.record("Expected notPersisted, got \(String(describing: error))")
            }
        }
    }

    @Test func savedSecretStillStartsWithoutAWordlist() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        try "saved-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try await withTestEnvironment(["RUNNER_SHARED_SECRET": nil]) {
            let resolved = try resolveStartupWorkerSecret(
                cliWorkerSecret: nil, workerSecretFilePath: secretPath,
                workerSecretWordlistPath: dir + "/absent-words.txt")
            #expect(resolved == "saved-secret")
        }
    }
}
