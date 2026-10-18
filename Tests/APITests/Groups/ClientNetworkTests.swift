// Tests/APITests/Groups/ClientNetworkTests.swift
//
// The network part of an address that a lab-group session stores in place of
// the address (docs/lab-groups.md, "Presence"), and which joins the check
// marks as from another network.

import Testing

@testable import APIServer

@Suite struct ClientNetworkTests {

    @Test(arguments: [
        ("129.97.12.34", "129.97.12.0/24"),
        (" 10.0.0.1 ", "10.0.0.0/24"),
        ("2620:101:f000:700:1:2:3:4", "2620:101:f000:700::/64"),
        ("2620:101:f000:700::1", "2620:101:f000:700::/64"),
        ("fe80::1%en0", "fe80:0:0:0::/64"),
        ("::ffff:129.97.12.34", "129.97.12.0/24"),
        ("::1", "0:0:0:0::/64"),
    ])
    func anAddressGivesItsNetwork(address: String, network: String) {
        #expect(ClientNetwork.prefix(of: address) == network)
    }

    @Test(arguments: [
        "unknown", "", "129.97.12", "129.97.12.300", "1:2:3", "1::2::3", "g::1", "1:2:3:4:5:6:7:8:9",
        "+1.2.3.4", "-1::", "1:1.2.3.4:5:6:7:8", "1.2.3.4:5678",
    ])
    func anythingElseHasNoNetwork(text: String) {
        #expect(ClientNetwork.prefix(of: text) == nil)
    }

    @Test func theRoomIsThePresentersNetworkAndTheCommonestJoins() {
        let lab = "129.97.12.0/24"
        let wired = "129.97.40.0/24"
        let home = "99.1.2.0/24"
        let joins = Array(repeating: lab, count: 10) + [home, nil]
        let room = SessionNetworkCheck.roomNetworks(presenter: wired, joins: joins)
        #expect(room == [wired, lab])
        #expect(SessionNetworkCheck.isOtherNetwork(home, room: room))
        #expect(!SessionNetworkCheck.isOtherNetwork(lab, room: room))
        #expect(!SessionNetworkCheck.isOtherNetwork(wired, room: room), "a student on the wired network is in the room")
        #expect(!SessionNetworkCheck.isOtherNetwork(nil, room: room), "an unknown network is never flagged")
        #expect(!SessionNetworkCheck.isOtherNetwork(home, room: []), "nothing known about the room flags nothing")
    }

    @Test func aTieKeepsEveryTiedNetwork() {
        let room = SessionNetworkCheck.roomNetworks(presenter: nil, joins: ["a", "b"])
        #expect(room == ["a", "b"], "one join each tells nothing, so neither is flagged")
    }

    @Test func aNetworkWithAFifthOfTheJoinsIsTheRoom() {
        let ipv4 = "129.97.12.0/24"
        let ipv6 = "2620:101:f000:700::/64"
        let joins = Array(repeating: ipv4, count: 14) + Array(repeating: ipv6, count: 10) + ["99.1.2.0/24"]
        let room = SessionNetworkCheck.roomNetworks(presenter: nil, joins: joins)
        #expect(room == [ipv4, ipv6], "the IPv6 half of a dual-stack room is the room")
        #expect(SessionNetworkCheck.isOtherNetwork("99.1.2.0/24", room: room))
    }
}
