// APIServer/Configuration/OutboundHTTPClientSetup.swift
//
// The one place that configures Vapor's shared outbound HTTP client (#2765).
// Every `app.client` and `req.client` call goes through that client: the SSO
// token exchange, OIDC discovery and JWKS, the LTI key set and AGS calls,
// BrightSpace, the alert webhook and the UW dates feed. Vapor sets no read
// timeout on it, so a peer that accepted the connection and then stopped
// answering held the caller for as long as the socket lived. That held an SSO
// callback open with no limit, and it held shutdown too: `BackgroundWork.drain()`
// and `PeriodicSweepMonitor.stop()` await their tasks, and a Vapor 4 client
// future does not end when its task is cancelled.
//
// The timeout is set on the client, not on each call, so a new call site gets
// it with no extra step. A call that needs a shorter limit still sets
// `ClientRequest.timeout` itself (`GitHubTransport.callTimeout`, the token
// revocation call).

import AsyncHTTPClient
import NIOCore
import Vapor

enum OutboundHTTPClientSetup {
    /// How long a connection attempt may take. This is the AsyncHTTPClient
    /// fallback (`HTTPConnectionPool.fallbackConnectTimeout`), written here so
    /// that the value does not change if the library default does.
    static let connectTimeout: TimeAmount = .seconds(30)

    /// How long the client waits for the next bytes from a peer. A peer that
    /// sends nothing for this long ends the call with an error. A call cannot
    /// raise this limit, so it equals the longest budget a caller already
    /// sets: the GitHub tarball download's 60 s (`GitHubRepoClient`). That
    /// download therefore behaves exactly as before.
    static let readTimeout: TimeAmount = .seconds(60)

    /// The timeout that the shared client uses.
    static var timeout: HTTPClient.Configuration.Timeout {
        HTTPClient.Configuration.Timeout(connect: connectTimeout, read: readTimeout)
    }

    /// Sets the timeout on Vapor's shared outbound client, and routes the
    /// client through `proxy` when one is set. Vapor builds
    /// `app.http.client.shared` lazily from this configuration, so this must
    /// run before the first `app.client` request.
    static func apply(to app: Application, proxy: OutboundProxyConfig?) {
        app.http.client.configuration.timeout = timeout
        guard let proxy else { return }
        app.http.client.configuration.proxy = .server(host: proxy.host, port: proxy.port)
        app.logger.info("Outbound HTTP client routed through proxy \(proxy.host):\(proxy.port)")
    }
}
