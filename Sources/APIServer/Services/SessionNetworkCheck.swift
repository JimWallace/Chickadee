// APIServer/Services/SessionNetworkCheck.swift
//
// Which joins of a lab-group session came from another network than the room
// (docs/lab-groups.md, "Presence"). A flag for staff, never a refusal: a
// network part says where a device is on the internet, not whether it is in
// the room, and a wrong refusal would lock out an honest student.

enum SessionNetworkCheck {

    /// The room's networks: the presenter's, the network that most joins came
    /// from, and every network that at least a fifth of the joins came from.
    /// The fifth keeps a room on two networks whole: on dual-stack Wi-Fi an
    /// IPv4 and an IPv6 address of one room share no prefix.
    static func roomNetworks(presenter: String?, joins: [String?]) -> Set<String> {
        let known = joins.compactMap(\.self)
        var counts: [String: Int] = [:]
        for network in known { counts[network, default: 0] += 1 }
        let most = counts.values.max() ?? 0
        var room = Set(counts.filter { $0.value == most || $0.value * 5 >= known.count }.keys)
        if let presenter { room.insert(presenter) }
        return room
    }

    /// True for a join from a known network that is not one of the room's.
    /// An unknown network is never flagged.
    static func isOtherNetwork(_ network: String?, room: Set<String>) -> Bool {
        guard let network, !room.isEmpty else { return false }
        return !room.contains(network)
    }
}
