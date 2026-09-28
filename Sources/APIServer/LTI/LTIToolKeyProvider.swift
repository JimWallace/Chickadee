// APIServer/LTI/LTIToolKeyProvider.swift
//
// Loads the LTI tool key on FIRST USE rather than at startup
// (docs/lti-1-3.md "The tool key"): a deployment that never registers a
// platform never writes `.lti-tool-key`, and test apps never pay for an RSA
// key generation they do not need.

import Vapor

actor LTIToolKeyProvider {
    private var authority: LTIToolKeyAuthority?
    private var loading: Task<LTIToolKeyAuthority, any Error>?

    /// The authority for the key at `path`, loading or generating it once.
    /// Concurrent first callers share one load, so two requests cannot race
    /// to write two different keys.
    func authority(path: String) async throws -> LTIToolKeyAuthority {
        if let authority { return authority }
        if let loading { return try await loading.value }
        let task = Task { try await LTIToolKeyAuthority.loadOrGenerate(path: path) }
        loading = task
        do {
            let loaded = try await task.value
            authority = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }
}

private struct LTIToolKeyProviderKey: StorageKey {
    typealias Value = LTIToolKeyProvider
}

private struct LTIToolKeyFilePathKey: StorageKey {
    typealias Value = String
}

extension Application {
    var ltiToolKeyProvider: LTIToolKeyProvider {
        lazyStored(LTIToolKeyProviderKey.self) { LTIToolKeyProvider() }
    }

    /// Where the tool key lives. Derived from the working directory, like
    /// `.worker-secret`, so it needs no environment variable.
    var ltiToolKeyFilePath: String {
        get {
            storage[LTIToolKeyFilePathKey.self]
                ?? (DirectoryConfiguration.detect().workingDirectory + ".lti-tool-key")
        }
        set { storage[LTIToolKeyFilePathKey.self] = newValue }
    }

    /// The tool key authority, loaded or generated on first use.
    func ltiToolKeyAuthority() async throws -> LTIToolKeyAuthority {
        try await ltiToolKeyProvider.authority(path: ltiToolKeyFilePath)
    }
}
