// APIServer/Services/ClassGoalSnapshot.swift
//
// The fields a class goal's snapshot carries, shared by the whole class's
// table and each lab group's (docs/lab-groups.md, slice 5a), so the sweep
// writes either one and the grade paths read either one.

import Fluent
import Foundation

/// The row that holds a class goal's snapshot: `APIAchievementResult` for the
/// whole class, `APIGroupAchievementResult` for a lab group.
protocol ClassGoalSnapshot: Model {
    var achievementID: String { get set }
    var studentsMeeting: Int { get set }
    var denominator: Int { get set }
    var progress: Double { get set }
    var itemsCovered: Int? { get set }
    var itemsRequired: Int? { get set }
    var coveragePercent: Double? { get set }
    var coverageRequired: Double? { get set }
    var locked: Bool { get set }
    var evaluatedAt: Date { get set }
}

extension APIAchievementResult: ClassGoalSnapshot {}
extension APIGroupAchievementResult: ClassGoalSnapshot {}
