// APIServer/Services/SessionNetworkCheck.swift
//
// Which joins of a lab-group session came from another network than the room
// (docs/lab-groups.md, "Presence"). A flag for staff, never a refusal: a
// network part says where a device is on the internet, not whether it is in
// the room, and a wrong refusal would lock out an honest student.

enum SessionNetworkCheck {

    /// The room's networks: the presenter's, and the network that most joins
    /// came from (every network tied for most).
    static func roomNetworks(presenter: String?, joins: [String?]) -> Set<String> {
        var counts: [String: Int] = [:]
        for network in joins.compactMap(\.self) { counts[network, default: 0] += 1 }
        let most = counts.values.max() ?? 0
        var room = Set(counts.filter { $0.value == most }.keys)
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
