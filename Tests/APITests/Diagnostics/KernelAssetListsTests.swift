// Tests/APITests/Diagnostics/KernelAssetListsTests.swift
//
// `KernelAssetLists` holds one boot-file list per vendored kernel and picks
// one for an assignment from its stored manifest. `KernelAssetListTests`
// reads the real vendored kernels; this suite builds a small fake
// `Public/jupyterlite` tree in a temporary directory, so it can control which
// kernels exist, which files are missing and what a file's size is.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct KernelAssetListsTests {

    private static func kernelName(_ language: AssignmentLanguage) throws -> String {
        guard case .notebookKernel(_, let name, _, _, _) = language.editorSupport else {
            throw IssueRecorded("\(language) has no notebook kernel")
        }
        return name
    }

    /// A temporary public directory. The caller removes it.
    private static func makePublicDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernel-asset-lists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a minimal vendored environment for `language`: a kernel spec,
    /// an environment meta with one package, the loader script and binary
    /// (with `binaryBytes` bytes), and the package tarball. `libxeus.so` is
    /// not written, so the list must skip it.
    private static func vendor(
        _ language: AssignmentLanguage, into publicDirectory: URL, binaryBytes: Int = 10,
        kernelJSON: String? = nil
    ) throws {
        let env = KernelEnvironment.environmentName(for: language)
        let kernel = try kernelName(language)
        let root = publicDirectory.appendingPathComponent("jupyterlite/xeus/\(env)")
        let manager = FileManager.default
        for directory in [kernel, "bin", "kernel_packages"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let spec = kernelJSON ?? #"{"argv":["xeus/\#(env)/bin/\#(kernel).js"]}"#
        try Data(spec.utf8).write(to: root.appendingPathComponent("\(kernel)/kernel.json"))
        try Data(#"{"packages":[{"filename":"pkg-1.0.tar.gz"}]}"#.utf8)
            .write(to: root.appendingPathComponent("empack_env_meta.json"))
        try Data("abc".utf8).write(to: root.appendingPathComponent("bin/\(kernel).js"))
        try Data(repeating: 0, count: binaryBytes).write(to: root.appendingPathComponent("bin/\(kernel).wasm"))
        try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("kernel_packages/pkg-1.0.tar.gz"))
    }

    // MARK: - load

    @Test func loadKeepsOnlyTheLanguagesWhoseFilesExist() throws {
        let publicDirectory = try Self.makePublicDirectory()
        defer { try? FileManager.default.removeItem(at: publicDirectory) }
        try Self.vendor(.python, into: publicDirectory)

        let lists = KernelAssetLists.load(publicDirectory: publicDirectory.path)
        let python = try #require(lists[.python])
        let kernel = try Self.kernelName(.python)
        let env = KernelEnvironment.environmentName(for: .python)
        #expect(python.env == env)
        #expect(python.base == "/jupyterlite/xeus/\(env)/")
        // libxeus.so is derived but absent on disk, so it is not listed.
        #expect(python.files == ["bin/\(kernel).js", "bin/\(kernel).wasm", "kernel_packages/pkg-1.0.tar.gz"])
        #expect(python.bytes == 3 + 10 + 5)
        #expect(python.version.count == 16)
        for language in AssignmentLanguage.allCases where language != .python {
            #expect(lists[language] == nil)
        }
    }

    @Test func theVersionChangesWhenABootFileChangesSize() throws {
        let first = try Self.makePublicDirectory()
        let second = try Self.makePublicDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Self.vendor(.python, into: first, binaryBytes: 10)
        try Self.vendor(.python, into: second, binaryBytes: 11)
        let firstList = try #require(KernelAssetList.load(publicDirectory: first.path, language: .python))
        let secondList = try #require(KernelAssetList.load(publicDirectory: second.path, language: .python))
        let again = try #require(KernelAssetList.load(publicDirectory: first.path, language: .python))
        #expect(firstList.version != secondList.version)
        #expect(firstList.version == again.version)
    }

    @Test func anUndecodableKernelSpecGivesNoList() throws {
        let publicDirectory = try Self.makePublicDirectory()
        defer { try? FileManager.default.removeItem(at: publicDirectory) }
        try Self.vendor(.python, into: publicDirectory, kernelJSON: "not json")
        #expect(KernelAssetList.load(publicDirectory: publicDirectory.path, language: .python) == nil)
    }

    @Test func anUndecodableKernelSpecIsNamedByItsKernel() {
        #expect(throws: KernelAssetList.DeriveError.undecodable("xpython/kernel.json")) {
            try KernelAssetList.relativeFiles(
                env: "chickadee-python", kernelName: "xpython", kernelJSON: Data("{".utf8),
                envMetaJSON: Data(#"{"packages":[]}"#.utf8))
        }
    }

    // MARK: - forManifest

    private static func manifest(language: String) -> String {
        #"{"schemaVersion":1,"language":"\#(language)","languageDeclared":true,"testSuites":[],"timeLimitSeconds":10}"#
    }

    @Test func forManifestPicksTheListOfTheDeclaredLanguage() throws {
        let python = KernelAssetList(env: "py", version: "1", base: "/py/", files: ["a"], bytes: 1)
        let lua = KernelAssetList(env: "lua", version: "2", base: "/lua/", files: ["b"], bytes: 2)
        let lists = KernelAssetLists(byLanguage: [.python: python, .lua: lua])
        #expect(lists.forManifest(json: Self.manifest(language: "python")) == python)
        #expect(lists.forManifest(json: Self.manifest(language: "lua")) == lua)
    }

    @Test func forManifestIsNilWhenThereIsNothingToWarm() {
        let python = KernelAssetList(env: "py", version: "1", base: "/py/", files: ["a"], bytes: 1)
        let lists = KernelAssetLists(byLanguage: [.python: python])
        // A declared language with no vendored list.
        #expect(lists.forManifest(json: Self.manifest(language: "r")) == nil)
        // An upload-only language.
        #expect(lists.forManifest(json: Self.manifest(language: "cpp")) == nil)
        // No declared language.
        #expect(lists.forManifest(json: TestManifests.emptySuite) == nil)
        // A manifest that does not decode.
        #expect(lists.forManifest(json: "{") == nil)
    }
}
