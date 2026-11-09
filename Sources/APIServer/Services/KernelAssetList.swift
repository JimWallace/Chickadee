// APIServer/Services/KernelAssetList.swift
//
// The files one vendored xeus kernel fetches when it boots, by URL, so the
// browser can measure how much of a boot came over the network and warm its
// HTTP cache before a class (docs/jupyterlite.md, "What a kernel boot
// downloads").
//
// The list is derived from the same two files the kernel reads, never typed
// out: `<kernel>/kernel.json` (the binary and the shared libraries the loader
// fetches beside it) and `empack_env_meta.json` (every package tarball). The
// editor's xeus worker and Chickadee's grading workers build the same URLs
// from those files, so a warm fetch of a URL here fills the cache entry the
// kernel later reads.
//
// Loaded once at boot, like `KernelEnvironments`. A checkout without the
// vendored bytes has no lists, and every caller then renders nothing.

import Core
import Crypto
import Foundation
import Vapor

/// One kernel's boot files.
struct KernelAssetList: Sendable, Encodable, Equatable {
    /// The vendored environment directory ("chickadee-python").
    let env: String
    /// Changes when any boot file changes: a hash of every file's name and
    /// size. Package names are content-addressed, and the binaries change
    /// size when they are rebuilt. The browser keys "already warmed" on it.
    let version: String
    /// The URL prefix every file below is relative to.
    let base: String
    /// The binary, its loader script, the kernel's shared libraries, then
    /// every package tarball, relative to `base`.
    let files: [String]
    /// The sum of the files' sizes on disk (gzip for the tarballs, the
    /// uncompressed bytes for the rest).
    let bytes: Int

    /// The list as the compact JSON that `kernel-asset-telemetry.js` reads
    /// from a data attribute.
    var json: String {
        Self.encodeJSON(self) ?? ""
    }

    /// Several lists as one JSON array, for the dashboard's warm script.
    static func encode(_ lists: [KernelAssetList]) -> String {
        encodeJSON(lists) ?? "[]"
    }

    private static func encodeJSON(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    // MARK: - Derivation

    private struct KernelSpec: Decodable {
        struct Metadata: Decodable {
            let shared: [String: String]?
        }
        let argv: [String]
        let metadata: Metadata?
    }

    private struct EnvMeta: Decodable {
        struct Package: Decodable {
            let filename: String
        }
        let packages: [Package]
    }

    enum DeriveError: Error, Equatable {
        case undecodable(String)
        case unexpectedBinaryPath(String)
    }

    /// The boot files, relative to the environment directory, from the
    /// kernel's own `kernel.json` and `empack_env_meta.json`.
    ///
    /// The paths mirror the loaders: `argv[0]` is `xeus/<env>/bin/<k>.js`
    /// and the binary is the same path ending `.wasm`; each `metadata.shared`
    /// key is fetched from `<kernel>/<key>`; `libxeus.so` comes from the
    /// environment root when the spec does not list it; each package is
    /// `kernel_packages/<filename>`.
    static func relativeFiles(
        env: String, kernelName: String, kernelJSON: Data, envMetaJSON: Data
    ) throws(DeriveError) -> [String] {
        let spec: KernelSpec
        let meta: EnvMeta
        do {
            spec = try JSONDecoder().decode(KernelSpec.self, from: kernelJSON)
        } catch {
            throw .undecodable("\(kernelName)/kernel.json")
        }
        do {
            meta = try JSONDecoder().decode(EnvMeta.self, from: envMetaJSON)
        } catch {
            throw .undecodable("empack_env_meta.json")
        }
        let prefix = "xeus/\(env)/"
        guard let script = spec.argv.first, script.hasPrefix(prefix), script.hasSuffix(".js") else {
            throw .unexpectedBinaryPath(spec.argv.first ?? "")
        }
        let loader = String(script.dropFirst(prefix.count))
        var files = [loader, String(loader.dropLast(".js".count)) + ".wasm"]
        let shared = spec.metadata?.shared ?? [:]
        files += shared.keys.sorted().map { "\(kernelName)/\($0)" }
        if shared["libxeus.so"] == nil {
            files.append("libxeus.so")
        }
        files += meta.packages.map { "kernel_packages/\($0.filename)" }
        return files
    }

    /// Loads one language's list from a public directory. Nil when the
    /// language has no vendored kernel, or the checkout lacks its files.
    static func load(publicDirectory: String, language: AssignmentLanguage) -> KernelAssetList? {
        guard case .notebookKernel(_, let kernelName, _, _, _) = language.editorSupport else { return nil }
        let env = KernelEnvironment.environmentName(for: language)
        let root = URL(fileURLWithPath: publicDirectory).appendingPathComponent("jupyterlite/xeus/\(env)")
        guard
            let kernelJSON = try? Data(contentsOf: root.appendingPathComponent("\(kernelName)/kernel.json")),
            let envMetaJSON = try? Data(contentsOf: root.appendingPathComponent("empack_env_meta.json")),
            let files = try? relativeFiles(
                env: env, kernelName: kernelName, kernelJSON: kernelJSON, envMetaJSON: envMetaJSON)
        else { return nil }

        var present: [String] = []
        var bytes = 0
        var fingerprint = ""
        for file in files {
            let path = root.appendingPathComponent(file).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = (attributes[.size] as? NSNumber)?.intValue
            else { continue }
            present.append(file)
            bytes += size
            fingerprint += "\(file)\t\(size)\n"
        }
        guard !present.isEmpty else { return nil }
        // Hex by hand: `String(format:)` is an unsafe (C varargs) construct
        // under strict memory safety.
        let digest = Data(SHA256.hash(data: Data(fingerprint.utf8)))
        let version = digest.prefix(8).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
        return KernelAssetList(
            env: env, version: version, base: "/jupyterlite/xeus/\(env)/", files: present, bytes: bytes)
    }
}

/// Every vendored kernel's boot files, keyed by language.
struct KernelAssetLists: Sendable {
    private let byLanguage: [AssignmentLanguage: KernelAssetList]

    init(byLanguage: [AssignmentLanguage: KernelAssetList]) {
        self.byLanguage = byLanguage
    }

    subscript(language: AssignmentLanguage) -> KernelAssetList? {
        byLanguage[language]
    }

    static func load(publicDirectory: String) -> KernelAssetLists {
        var loaded: [AssignmentLanguage: KernelAssetList] = [:]
        for language in AssignmentLanguage.allCases {
            if let list = KernelAssetList.load(publicDirectory: publicDirectory, language: language) {
                loaded[language] = list
            }
        }
        return KernelAssetLists(byLanguage: loaded)
    }

    /// The list for an assignment's declared language, from its stored
    /// manifest. Nil for no declared language, an upload-only one, or a
    /// manifest that does not decode: this renders a page, so it never fails.
    func forManifest(json: String) -> KernelAssetList? {
        guard let manifest = decodeManifest(fromJSON: json),
            let language = AssignmentLanguage.resolve(manifest: manifest)
        else { return nil }
        return self[language]
    }
}

extension Application {
    private struct KernelAssetListsKey: StorageKey {
        typealias Value = KernelAssetLists
    }

    /// The vendored kernels' boot files, loaded once at boot. Nil before then
    /// and in a test app that never loads them.
    var kernelAssetLists: KernelAssetLists? {
        get { storage[KernelAssetListsKey.self] }
        set { storage[KernelAssetListsKey.self] = newValue }
    }
}
