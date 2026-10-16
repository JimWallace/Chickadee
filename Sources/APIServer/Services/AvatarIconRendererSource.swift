// APIServer/Services/AvatarIconRendererSource.swift
//
// The tab-icon renderer, built on first use and then kept. Production builds
// it at boot (`loadAvatarIconRenderer`), so a request only reads it. A test app
// skips `configure`, and most never request an icon: building the renderer for
// each of them would cost a fraction of a second per app for nothing.

import Synchronization

final class AvatarIconRendererSource: Sendable {
    private let build: @Sendable () -> Result<AvatarIconRenderer, AvatarIconRendererError>
    private let built = Mutex<Result<AvatarIconRenderer, AvatarIconRendererError>?>(nil)

    init(_ build: @escaping @Sendable () -> Result<AvatarIconRenderer, AvatarIconRendererError>) {
        self.build = build
    }

    /// The renderer, or why it could not be built. The first call builds it.
    func renderer() throws(AvatarIconRendererError) -> AvatarIconRenderer {
        let result = built.withLock { built in
            if let built { return built }
            let result = build()
            built = result
            return result
        }
        return try result.get()
    }
}
