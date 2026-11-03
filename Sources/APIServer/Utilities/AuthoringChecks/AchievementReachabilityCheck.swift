// APIServer/Utilities/AuthoringChecks/AchievementReachabilityCheck.swift
//
// Reports each authored achievement that can never be awarded (#2747). Saving
// achievements refuses a bad reference (`AchievementsEditing.validate`), but a
// later suite edit can delete the test or section that one points at, and a
// hand-authored manifest skips that door entirely. Every rule here is read
// from Core, not restated: `allTestRefNames`, `isSweepEvaluableClassGoal`,
// `coveredItemsRequirement` and `coveredItemNames(inScopeOf:)`.

import Core

struct AchievementReachabilityCheck: AuthoringCheck {
    static let id = "achievements.neverAwarded"
    static let severity = AuthoringFinding.Severity.error

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        let manifest = snapshot.manifest
        let testRefs = manifest.allTestRefNames
        let sectionIDs = Set(manifest.sections.map(\.id))
        let disabled = Set(manifest.disabledBuiltInAwardIDs)
        var found: [AuthoringFinding] = []
        // An award switched off on purpose is never evaluated, so it is not a
        // problem that it could not fire.
        for achievement in manifest.achievements where !disabled.contains(achievement.id) {
            var dangling = false
            func report(_ reason: String, fix: String) {
                found.append(
                    finding(
                        at: .assignment, "Achievement \"\(achievement.name)\" can never be awarded: \(reason)", fix: fix
                    ))
            }
            for condition in achievement.conditions {
                switch condition.signal {
                case .testPass:
                    let ref = condition.target?.ref ?? ""
                    if !testRefs.contains(ref) {
                        dangling = true
                        report(
                            ref.isEmpty
                                ? "its test-passes condition names no test."
                                : "its condition names the test \"\(ref)\", which is not in the suite.",
                            fix: "Point the condition at a test that exists, or remove it.")
                    }
                case .itemsCovered:
                    if let ref = condition.target?.ref, !sectionIDs.contains(ref) {
                        dangling = true
                        report(
                            "its condition counts suite section \"\(ref)\", which no longer exists.",
                            fix: "Point it at a section that exists, or clear it to count the whole suite.")
                    }
                default:
                    continue
                }
            }
            // A dangling reference is already reported. It would also make
            // the shape and the item count fail, so neither is reported twice.
            guard !dangling else { continue }
            if achievement.isClassGoal, !achievement.isSweepEvaluableClassGoal {
                report(
                    "it is a class goal of a shape the class-goal sweep does not evaluate.",
                    fix: "Change it to a shape that \"Class goals in force\" in "
                        + "docs/collaborative-class-assignments.md lists.")
            } else if let requirement = achievement.coveredItemsRequirement {
                let available = manifest.coveredItemNames(inScopeOf: requirement.scope).count
                if requirement.count > available {
                    report(
                        "it asks the class to cover \(requirement.count) items, but only \(available) "
                            + "count toward it.",
                        fix: "Lower the count to at most \(available), or widen its scope.")
                }
            }
        }
        return found
    }
}
