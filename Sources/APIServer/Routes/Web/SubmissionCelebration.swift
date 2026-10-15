// APIServer/Routes/Web/SubmissionCelebration.swift
//
// What the result page needs to play its celebration
// (docs/result-celebration.md, J1). The page renders it as data attributes on
// the grade band, and `Public/celebrate.js` reads them.

import Core

/// One result's celebration, as the page renders it.
struct SubmissionCelebration: Encodable, Equatable {
    let state: ResultCelebration
    /// The percent the count-up ends on.
    let gradeTo: Int
    /// The percent the count-up starts from: the previous attempt's for
    /// `improved`, else 0.
    let gradeFrom: Int
    let passCount: Int
    let totalTests: Int

    init(state: ResultCelebration, gradeTo: Int, gradeFrom: Int, passCount: Int, totalTests: Int) {
        self.state = state
        self.gradeTo = gradeTo
        self.gradeFrom = state == .improved ? gradeFrom : 0
        self.passCount = passCount
        self.totalTests = totalTests
    }

    /// The percent gained since the previous attempt, for the "+N%" pill;
    /// nil unless the state is `improved`.
    var gain: Int? { state == .improved ? gradeTo - gradeFrom : nil }

    /// The sentence the polite live region reads at the pop.
    var announcement: String {
        if passCount == totalTests {
            return "All \(totalTests) tests passed, \(gradeTo)%."
        }
        let tests = "\(passCount) of \(totalTests) tests passed, \(gradeTo)%"
        guard gain != nil else { return tests + "." }
        return tests + ", up from \(gradeFrom)%."
    }
}
