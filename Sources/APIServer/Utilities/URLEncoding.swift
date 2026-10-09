// APIServer/Utilities/URLEncoding.swift
//
// The one percent-encoder for a query-parameter value (#2492). The web
// redirects and the BrightSpace Valence auth URL each had a copy.

import Foundation

/// Percent-encodes a query-parameter value, so reserved characters (`:` `/`
/// `?` `=` `&`) in it do not leak into the surrounding query. Only letters,
/// digits and `-._~` stay as they are. Equivalent to Python's
/// `urllib.parse.quote(value, safe='')`.
func urlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}
