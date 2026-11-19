// APIServer/MCP/Protocol/MCPWardrobeItemProse.swift
//
// How the wardrobe items an achievement may grant are SPELLED in the
// agent-facing copy (docs/achievement-rewards.md, decision 4, slice S2),
// derived from `WardrobeItem.grantable` in one place, as the language and tier
// lists are. A new grantable item needs no edit to any MCP prose, and
// `MCPWardrobeItemCoverageTests` fails on a hand-typed list that stops short.

import Core

/// The grantable wardrobe items, rendered for agent-facing copy.
enum MCPWardrobeItemProse {

    /// The raw values an agent writes in `rewardItem`, for a schema enum.
    static var values: [String] { WardrobeItem.grantable.map(\.rawValue) }

    /// Each item with the name a student reads:
    /// `"border.spectrum (Spectrum), border.crossfade (Cross-fade)"`.
    static var commaList: String {
        WardrobeItem.grantable.map { "\($0.rawValue) (\($0.displayName))" }.joined(separator: ", ")
    }

    /// The clause the tool descriptions and the instructions share.
    static var rewardClause: String {
        "An individual row may instead grant a wardrobe item for the student's bird: set "
            + "rewardType \"wardrobe\" and rewardItem to one of " + commaList + ". The item is "
            + "hidden from students until earned, it is kept once granted, and it is account-wide, so "
            + "a student who already holds it earns nothing new. A classWide goal, a record and a "
            + "course achievement cannot grant one"
    }
}
