// APIServer/Utilities/ClientNetwork.swift
//
// The network part of a client's IP address (docs/lab-groups.md, "Presence"):
// the first three parts of an IPv4 address (a /24), or the first four groups
// of an IPv6 address (a /64). A lab-group session stores this, never the full
// address, and compares it with the presenter's to flag a join from another
// network.

import Foundation

enum ClientNetwork {

    /// "129.97.12.0/24" for "129.97.12.34", "2620:101:f000:700::/64" for an
    /// IPv6 address in that /64, and nil for anything that is not an IP
    /// address ("unknown" in tests). An IPv4 address carried in IPv6
    /// ("::ffff:129.97.12.34") is read as IPv4.
    static func prefix(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if let ipv4 = ipv4Parts(trimmed) {
            return "\(ipv4[0]).\(ipv4[1]).\(ipv4[2]).0/24"
        }
        guard let groups = ipv6Groups(trimmed) else { return nil }
        if groups[0..<5].allSatisfy({ $0 == 0 }), groups[5] == 0xFFFF {
            return "\(groups[6] >> 8).\(groups[6] & 0xFF).\(groups[7] >> 8).0/24"
        }
        return groups[0..<4].map { String($0, radix: 16) }.joined(separator: ":") + "::/64"
    }

    private static func ipv4Parts(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part in Int(part).flatMap { (0...255).contains($0) ? $0 : nil } }
        return numbers.count == 4 ? numbers : nil
    }

    /// The eight 16-bit groups of an IPv6 address, with `::` expanded and an
    /// embedded IPv4 tail read as two groups. A zone ("%en0") is dropped.
    private static func ipv6Groups(_ text: String) -> [Int]? {
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        guard address.contains(":") else { return nil }
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ half: String) -> [Int]? {
            guard !half.isEmpty else { return [] }
            var result: [Int] = []
            for part in half.split(separator: ":", omittingEmptySubsequences: false) {
                if part.contains("."), let ipv4 = ipv4Parts(String(part)) {
                    result += [ipv4[0] << 8 | ipv4[1], ipv4[2] << 8 | ipv4[3]]
                } else if part.count <= 4, let value = Int(part, radix: 16) {
                    result.append(value)
                } else {
                    return nil
                }
            }
            return result
        }
        guard let head = groups(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }
}
