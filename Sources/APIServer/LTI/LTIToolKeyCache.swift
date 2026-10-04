// APIServer/LTI/LTIToolKeyCache.swift
//
// Loads the LTI tool key on FIRST USE rather than at startup
// (docs/lti-1-3.md "The tool key"): a deployment that never registers a
// platform never writes `.lti-tool-key`, and test apps never pay for an RSA
// key generation they do not need.

import Vapor

/// The tool key, loaded once: an infinite TTL, so concurrent first callers
/// share one load and two requests cannot race to write two different keys.
/// The coalescing is `SingleFlightCache`; this names the specialisation.
typealias LTIToolKeyCache = SingleFlightCache<LTIToolKeyAuthority>

extension SingleFlightCache where Value == LTIToolKeyAuthority {
    /// The authority for the key at `path`, loading or generating it once.
    func authority(path: String) async throws -> LTIToolKeyAuthority {
        try await value { try await LTIToolKeyAuthority.loadOrGenerate(path: path) }
    }
}

private struct LTIToolKeyCacheKey: StorageKey {
    typealias Value = LTIToolKeyCache
}

private struct LTIToolKeyFilePathKey: StorageKey {
    typealias Value = String
}

extension Application {
    var ltiToolKeyCache: LTIToolKeyCache {
        lazyStored(LTIToolKeyCacheKey.self) { LTIToolKeyCache(ttl: .infinity) }
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
        try await ltiToolKeyCache.authority(path: ltiToolKeyFilePath)
    }
}
