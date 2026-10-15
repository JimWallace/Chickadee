// Tests/CoreTests/AvatarReactionTests.swift
//
// The bird reacts only to a clean pass, and the reaction changes what one page
// shows, never the stored bird (Core/AvatarReaction.swift).

import Testing

@testable import Core

@Suite struct AvatarReactionTests {

    struct Result: Sendable, CustomTestStringConvertible {
        let passCount: Int
        let totalTests: Int
        let buildFailed: Bool
        let isPending: Bool
        let expected: AvatarReaction
        let testDescription: String
    }

    @Test(arguments: [
        Result(
            passCount: 4, totalTests: 4, buildFailed: false, isPending: false, expected: .cheer,
            testDescription: "every test passed"),
        Result(
            passCount: 3, totalTests: 4, buildFailed: false, isPending: false, expected: .none,
            testDescription: "one test failed"),
        Result(
            passCount: 0, totalTests: 4, buildFailed: false, isPending: false, expected: .none,
            testDescription: "every test failed"),
        Result(
            passCount: 0, totalTests: 0, buildFailed: false, isPending: false, expected: .none,
            testDescription: "no tests"),
        Result(
            passCount: 0, totalTests: 0, buildFailed: true, isPending: false, expected: .none,
            testDescription: "the build failed"),
        Result(
            passCount: 0, totalTests: 0, buildFailed: false, isPending: true, expected: .none,
            testDescription: "waiting for a runner"),
    ])
    func reactionFollowsTheResult(_ result: Result) {
        let reaction = AvatarReaction(
            passCount: result.passCount, totalTests: result.totalTests,
            buildFailed: result.buildFailed, isPending: result.isPending)
        #expect(reaction == result.expected)
    }

    @Test func cheerShowsTheChirpFaceAndChangesNothingElse() {
        let spec = AvatarSpec.drawn(fromSeed: 7)
        let shown = AvatarReaction.cheer.applied(to: spec)
        #expect(shown.expression == .chirp)
        var expected = spec
        expected.expression = .chirp
        #expect(shown == expected)
    }

    @Test func noReactionShowsTheBirdAsItIs() {
        let spec = AvatarSpec.drawn(fromSeed: 7)
        #expect(AvatarReaction.none.applied(to: spec) == spec)
    }
}
