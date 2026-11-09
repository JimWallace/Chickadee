// Tests/APITests/Diagnostics/KernelAssetListTests.swift
//
// KernelAssetList names the files a kernel boot fetches, so a warm fetch or a
// cache probe of those URLs reads the cache entry the kernel later uses. The
// derivation must follow the loaders: the binary beside its loader script,
// each `metadata.shared` library under the kernel directory, and every
// package tarball. The vendored-bytes tests read the real kernels in
// Public/jupyterlite/xeus/, so a re-vendor that changes the layout fails
// here rather than silently warming the wrong URLs.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct KernelAssetListTests {
    private let meta = Data(
        #"{"prefix":"/","packages":[{"filename":"python-3.13.tar.gz"},{"filename":"numpy-2.5.tar.gz"}]}"#.utf8)

    @Test func theFilesFollowTheKernelSpecAndTheEnvironment() throws {
        let spec = Data(
            """
            {"argv":["xeus/chickadee-r/bin/xr.js","-f","{connection_file}"],
             "metadata":{"shared":{"libxeus.so":"lib/libxeus.so","libR.so":"lib/R/lib/libR.so"}}}
            """.utf8)
        let files = try KernelAssetList.relativeFiles(
            env: "chickadee-r", kernelName: "xr", kernelJSON: spec, envMetaJSON: meta)
        #expect(
            files == [
                "bin/xr.js", "bin/xr.wasm", "xr/libR.so", "xr/libxeus.so",
                "kernel_packages/python-3.13.tar.gz", "kernel_packages/numpy-2.5.tar.gz",
            ])
    }

    @Test func aKernelThatListsNoLibxeusLoadsItFromTheEnvironmentRoot() throws {
        let spec = Data(#"{"argv":["xeus/chickadee-lua/bin/xlua.js"]}"#.utf8)
        let files = try KernelAssetList.relativeFiles(
            env: "chickadee-lua", kernelName: "xlua", kernelJSON: spec, envMetaJSON: meta)
        #expect(files.prefix(3) == ["bin/xlua.js", "bin/xlua.wasm", "libxeus.so"])
    }

    @Test func aBinaryOutsideTheEnvironmentIsRefused() {
        let spec = Data(#"{"argv":["elsewhere/bin/xpython.js"]}"#.utf8)
        #expect(throws: KernelAssetList.DeriveError.unexpectedBinaryPath("elsewhere/bin/xpython.js")) {
            try KernelAssetList.relativeFiles(
                env: "chickadee-python", kernelName: "xpython", kernelJSON: spec, envMetaJSON: meta)
        }
    }

    @Test func undecodableInputIsNamed() {
        #expect(throws: KernelAssetList.DeriveError.undecodable("empack_env_meta.json")) {
            try KernelAssetList.relativeFiles(
                env: "chickadee-python", kernelName: "xpython",
                kernelJSON: Data(#"{"argv":["xeus/chickadee-python/bin/xpython.js"]}"#.utf8),
                envMetaJSON: Data("not json".utf8))
        }
    }

    private static var publicDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Public").path
    }

    private static func kernelName(_ language: AssignmentLanguage) -> String? {
        switch language.editorSupport {
        case .notebookKernel(_, let name, _, _, _): name
        case .uploadOnly: nil
        }
    }

    private static let kernelLanguages = AssignmentLanguage.allCases.filter { kernelName($0) != nil }

    @Test func anUploadOnlyLanguageHasNoList() {
        for language in AssignmentLanguage.allCases where Self.kernelName(language) == nil {
            #expect(KernelAssetList.load(publicDirectory: Self.publicDirectory, language: language) == nil)
        }
    }

    /// Every vendored kernel has a list, every listed file exists, and every
    /// package in the environment is in it.
    @Test(arguments: kernelLanguages)
    func theVendoredKernelsListEveryBootFile(language: AssignmentLanguage) throws {
        let list = KernelAssetList.load(publicDirectory: Self.publicDirectory, language: language)
        let kernelName = try #require(Self.kernelName(language))
        let found = try #require(list)
        let env = KernelEnvironment.environmentName(for: language)
        #expect(found.env == env)
        #expect(found.base == "/jupyterlite/xeus/\(env)/")
        #expect(found.version.count == 16)
        #expect(found.files.contains("bin/\(kernelName).wasm"))
        #expect(found.files.contains("bin/\(kernelName).js"))
        let root = URL(fileURLWithPath: Self.publicDirectory).appendingPathComponent("jupyterlite/xeus/\(env)")
        let packages = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("kernel_packages").path
        ).filter { $0.hasSuffix(".tar.gz") }
        #expect(
            Set(found.files.filter { $0.hasPrefix("kernel_packages/") })
                == Set(packages.map { "kernel_packages/\($0)" }))
        #expect(found.bytes > 0)
    }

    @Test func theJSONCarriesTheFieldsTheBrowserReads() throws {
        let list = KernelAssetList(
            env: "chickadee-python", version: "0123456789abcdef", base: "/jupyterlite/xeus/chickadee-python/",
            files: ["bin/xpython.wasm"], bytes: 9)
        let decoded = try JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [String: Any]
        #expect(decoded?["env"] as? String == "chickadee-python")
        #expect(decoded?["base"] as? String == "/jupyterlite/xeus/chickadee-python/")
        #expect(decoded?["files"] as? [String] == ["bin/xpython.wasm"])
        #expect(KernelAssetList.encode([list, list]).hasPrefix("[{"))
        #expect(!list.json.contains(#"\/"#))
    }
}
