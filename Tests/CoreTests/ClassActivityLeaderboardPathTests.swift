// Tests/CoreTests/ClassActivityLeaderboardPathTests.swift
//
// `ClassActivity.leaderboardPath` is the one rule every link to a class
// activity's board asks: the dashboards' Actions columns and the submission
// page. Staff always reach the board; a student only once it is visible.

import Core
import Testing

@Suite struct ClassActivityLeaderboardPathTests {

    @Test(arguments: ActivityKind.allCases)
    func staffAlwaysGetThePath(kind: ActivityKind) {
        let hidden = ClassActivity(kind: kind, leaderboardVisibility: .hidden)
        #expect(
            hidden.leaderboardPath(testSetupID: "setup_1", viewerIsStaff: true)
                == "/testsetups/setup_1/leaderboard")
    }

    @Test func aStudentGetsThePathOnlyWhenTheBoardIsVisible() {
        let hidden = ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .hidden)
        let visible = ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .visible)
        #expect(hidden.leaderboardPath(testSetupID: "setup_1", viewerIsStaff: false) == nil)
        #expect(
            visible.leaderboardPath(testSetupID: "setup_1", viewerIsStaff: false)
                == "/testsetups/setup_1/leaderboard")
    }
}
