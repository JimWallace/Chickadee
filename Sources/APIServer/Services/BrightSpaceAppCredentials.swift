// APIServer/Services/BrightSpaceAppCredentials.swift
//
// The deployment-level half of the D2L Valence "App + User" credential pair.
//
// The app registration (URL + App ID + App Key) is ops-managed and read from
// env. The *user* key, by contrast, can be supplied two ways: via env
// (BRIGHTSPACE_USER_ID/KEY, the original mechanism) or captured through the
// admin "Authorize BrightSpace" flow and persisted in `brightspace_credentials`
// (see BrightSpaceCredentialStore). Splitting the app creds out lets the server
// build the Valence authorization URL — and reach the admin authorize page —
// even before any user key exists.
//
// Auth-URL signing mirrors scripts/brightspace-valence-auth.py and the
// per-request signing in BrightSpaceAPIClient: HMAC-SHA256 over the raw
// callback, base64url (no padding); the callback is fully percent-encoded in
// the x_target query parameter.

import Crypto
import Foundation
import Vapor

struct BrightSpaceAppCredentials: Sendable {
    let baseURL: String
    let appID: String
    let appKey: String
    let debounceSecs: TimeInterval

    /// Present whenever the three deployment-level vars are set, regardless of
    /// whether a user key is configured. `BrightSpaceSyncConfig.fromEnvironment`
    /// remains the "all four present in env" path used as a fallback.
    static func fromEnvironment() -> Self? {
        guard
            let base = trimmedEnv("BRIGHTSPACE_URL"),
            let appID = trimmedEnv("BRIGHTSPACE_APP_ID"),
            let appKey = trimmedEnv("BRIGHTSPACE_APP_KEY")
        else { return nil }
        let debounce = environmentDouble("BRIGHTSPACE_SYNC_DEBOUNCE_SECS") ?? 90
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return BrightSpaceAppCredentials(
            baseURL: trimmedBase,
            appID: appID,
            appKey: appKey,
            debounceSecs: debounce > 0 ? debounce : 90
        )
    }

    /// The signed Valence URL the admin's browser visits to authorize the app.
    /// `callback` is the absolute Trusted-URL the LMS redirects back to (it may
    /// already carry a `?state=` CSRF parameter); D2L appends `x_a`/`x_b`.
    func valenceAuthURL(callback: String) -> String {
        let sig = brightSpaceHMACSHA256Base64URL(key: appKey, message: callback)
        return "\(baseURL)/d2l/auth/api/token"
            + "?x_a=\(valenceEncoded(appID))"
            + "&x_b=\(valenceEncoded(sig))"
            + "&x_target=\(valenceEncoded(callback))"
    }
}

extension BrightSpaceSyncConfig {
    /// Assembles a full sync config from deployment app creds plus a resolved
    /// user key (env- or authorize-sourced).
    init(app: BrightSpaceAppCredentials, userID: String, userKey: String) {
        self.init(
            baseURL: app.baseURL,
            appID: app.appID,
            appKey: app.appKey,
            userID: userID,
            userKey: userKey,
            debounceSecs: app.debounceSecs
        )
    }
}

// MARK: - Signing helpers

/// The base string signed (with app key → `x_c`, user key → `x_d`) for an
/// authenticated Valence request: `"<METHOD>&<lowercase_path>&<timestamp>"`,
/// timestamp in seconds. Verified against Brightspace's valence-sdk-python
/// (`'{0}&{1}&{2}'.format(method.upper(), path.lower(), time)`). Shared by
/// `BrightSpaceAPIClient.signed` and pinned by tests.
func valenceRequestBaseString(method: String, path: String, timestamp: Int) -> String {
    "\(method.uppercased())&\(path.lowercased())&\(timestamp)"
}

/// HMAC-SHA256, base64url-encoded with padding stripped. Matches
/// `BrightSpaceAPIClient.hmacSHA256Base64URL` and the Python helper's `d2l_sig`.
func brightSpaceHMACSHA256Base64URL(key: String, message: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
    return Data(mac).base64URLEncodedString()
}

/// The path component fed to `valenceRequestBaseString`: the portion of
/// `urlString` between the host and the query (`?`) / fragment (`#`),
/// percent-decoded. Mirrors the reference client's `unquote_plus(path.lower())`
/// (`valenceRequestBaseString` applies the lowercasing). Unlike
/// `URL(string:)?.path` this never returns nil, so a URL Foundation declines to
/// parse is still signed rather than silently sent unauthenticated. Our request
/// URLs only ever carry numeric IDs and lowercase route names in the path — the
/// one caller-supplied value, `orgDefinedId`, rides in the query — so no
/// percent-encoded alphabetic character can reach the path, making this
/// decode-then-lowercase order equivalent to the reference's lowercase-then-decode.
func valencePath(of urlString: String) -> String {
    var path = Substring(urlString)
    if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
        path = path[..<cut]
    }
    if let scheme = path.range(of: "://") {
        let afterHost = path[scheme.upperBound...]
        if let slash = afterHost.firstIndex(of: "/") {
            path = afterHost[slash...]
        } else {
            return "/"
        }
    }
    let raw = String(path)
    return raw.removingPercentEncoding ?? raw
}

/// The URL of the next page in a Valence list response, or nil when pagination
/// is complete. Mirrors the reference client's `get_paged`, which follows either
/// D2L paging convention:
///   • `PagingInfo` / `Bookmark` — re-issue the first-page URL with
///     `?bookmark=<bm>` while `HasMoreItems` is true;
///   • `Next` — a continuation URL (absolute, or a path relative to the host).
func valenceNextPageURL(
    firstPageURL: String,
    baseURL: String,
    pagingBookmark: String?,
    pagingHasMore: Bool?,
    next: String?
) -> String? {
    // Bookmark convention: a `PagingInfo` block was present.
    if pagingHasMore != nil || pagingBookmark != nil {
        guard pagingHasMore == true, let bookmark = pagingBookmark, !bookmark.isEmpty else {
            return nil
        }
        let encoded = bookmark.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bookmark
        let basePath = firstPageURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? firstPageURL
        return "\(basePath)?bookmark=\(encoded)"
    }
    // Continuation-URL convention.
    if let next, !next.isEmpty {
        if next.hasPrefix("http://") || next.hasPrefix("https://") { return next }
        return baseURL + (next.hasPrefix("/") ? next : "/" + next)
    }
    return nil
}

/// Parses D2L's clock-skew error body. A request whose `x_t` timestamp is
/// outside the server's tolerance gets HTTP 403 with the body
/// `"Timestamp out of range, <serverUnixTimeSeconds>"`. Returns the server's
/// Unix time (seconds) so the client can set its skew and retry, or nil when the
/// body isn't a timestamp error (e.g. a genuine permission 403).
func valenceServerTimeFromTimestampError(body: String) -> Int? {
    guard body.range(of: "Timestamp out of range", options: .caseInsensitive) != nil else {
        return nil
    }
    let digits = body.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
    return Int(digits)
}

/// Percent-encodes a query-parameter value so reserved characters (`:` `/` `?`
/// `=` `&`) in the callback don't leak into the surrounding query. Equivalent
/// to Python's `urllib.parse.quote(value, safe='')`.
private func valenceEncoded(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

// MARK: - Application storage

struct BrightSpaceAppCredentialsKey: StorageKey {
    typealias Value = BrightSpaceAppCredentials
}

extension Application {
    /// Deployment-level BrightSpace app creds (env). Non-nil whenever the three
    /// app vars are set — even when no user key is configured yet, so the admin
    /// authorize flow can build the Valence URL.
    var brightSpaceAppCredentials: BrightSpaceAppCredentials? {
        get { storage[BrightSpaceAppCredentialsKey.self] }
        set { storage[BrightSpaceAppCredentialsKey.self] = newValue }
    }
}
