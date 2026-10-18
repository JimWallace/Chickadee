// APIServer/Services/ActivitySessionCode.swift
//
// The join code of a per-group session (docs/lab-groups.md, "Presence"). The
// code changes every `period` seconds, so a code sent out of the room stops
// working soon after. It is not stored: each session keeps a random secret,
// and the code for a time step is an HMAC of the step under that secret. A join
// takes the current code and the one before it, so a student who is typing
// when the code changes is not refused.

import Crypto
import Foundation

enum ActivitySessionCode {

    /// Capitals and digits with no look-alike pair (no 0 and O, 1 and I, 2 and
    /// Z, 5 and S, 8 and B), so a code read off a projector is typed right the
    /// first time.
    static let alphabet: [Character] = Array("ACDEFGHJKMNPQRTUVWXY34679")
    static let length = 5
    /// How long one code shows on the projector.
    static let period: TimeInterval = 30

    /// A new random secret for a session that starts or starts again.
    static func newSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    /// The code on the projector at `date`.
    static func code(secret: String, at date: Date) -> String {
        code(secret: secret, step: step(at: date))
    }

    /// Whether `typed` is the code at `date` or the one before it. Letter case,
    /// spaces and dashes in `typed` do not count.
    static func matches(_ typed: String, secret: String, at date: Date) -> Bool {
        let typed = normalized(typed)
        let step = step(at: date)
        return typed == code(secret: secret, step: step) || typed == code(secret: secret, step: step - 1)
    }

    /// Whole seconds until the code at `date` changes, from 1 to `period`.
    static func secondsLeft(at date: Date) -> Int {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return Int((period - elapsed).rounded(.up))
    }

    static func normalized(_ typed: String) -> String {
        String(typed.uppercased().filter { !$0.isWhitespace && $0 != "-" })
    }

    private static func step(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / period).rounded(.down))
    }

    private static func code(secret: String, step: Int64) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(String(step).utf8), using: SymmetricKey(data: Data(secret.utf8)))
        var value = mac.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let base = UInt64(alphabet.count)
        var characters: [Character] = []
        for _ in 0..<length {
            characters.append(alphabet[Int(value % base)])
            value /= base
        }
        return String(characters)
    }
}
