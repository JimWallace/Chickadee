// APIServer/Routes/Web/BuiltInRuleRow.swift
//
// One row of "Built in" on the course Achievements tab
// (docs/achievement-rewards.md, S4).

import Core

/// One built-in wardrobe rule, read-only (docs/achievement-rewards.md,
/// decision 8): what every student earns with no setup.
struct BuiltInRuleRow: Sendable {
    let itemName: String
    /// "Earned when every test passed on three assignments".
    let howEarned: String

    init(_ item: WardrobeItem) {
        itemName = item.displayName
        howEarned = "Earned \(item.howEarned)"
    }
}
