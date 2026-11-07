// APIServer/Utilities/URLEncoding.swift
//
// The one percent-encoder for a query-parameter value (#2492) and for one URL
// path segment. The web redirects and the BrightSpace Valence auth URL each
// had a copy. A course key in a link is a segment: `.urlPathAllowed` keeps "/",
// which would split a key with a "/" in two. RoutingKit decodes each route
// parameter (`Parameters.set`), so a segment encoded here reaches its route.

import Foundation

/// Percent-encodes a query-parameter value or a path segment, so reserved
/// characters (`:` `/` `?` `=` `&` `#`) in it do not leak into the URL. Only letters,
/// digits and `-._~` stay as they are. Equivalent to Python's
/// `urllib.parse.quote(value, safe='')`.
func urlEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: urlEncodeAllowedCharacters) ?? ""
}

/// Letters, digits and `-._~`, built once: copying and extending
/// `CharacterSet.alphanumerics` cost more than the encoding itself, and a
/// roster row encodes two links. `CharacterSet` is a `Sendable` value.
private let urlEncodeAllowedCharacters: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return allowed
}()
