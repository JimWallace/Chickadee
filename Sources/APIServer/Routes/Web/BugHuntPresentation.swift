// APIServer/Routes/Web/BugHuntPresentation.swift
//
// What a bug hunt's board shows (docs/bug-hunt-code-map.md): the share of the
// listed items the class has covered and, when the block carries code, each
// line of it in its state. Built for the projector and the staff leaderboard
// page; students never reach either, because a bug hunt's leaderboard stays
// hidden (`ActivityAuthoring.bugHuntLeaderboardHiddenMessage`).
//
// No names: the board shows what the class covered, not who covered it.

import Core
import Fluent
import Foundation
import Vapor

/// One line of the code map.
struct BugHuntCodeLine: Equatable, Sendable {
    let number: Int
    let text: String
    let state: BugHuntLineState
}

struct BugHuntPresentation: Equatable, Sendable {
    /// "70%".
    let percentText: String
    /// "7 of 10".
    let countText: String
    /// Empty when the block carries no code: the board shows the percentage
    /// alone.
    let lines: [BugHuntCodeLine]
    /// False when the starter notebook declares no contribution slots: no
    /// result then records coverage, so the board would never move.
    var recordsCoverage: Bool = true

    var showsCode: Bool { !lines.isEmpty }

    static func make(spec: BugHuntSpec, coverage: BugHuntCoverage) -> BugHuntPresentation {
        let states = spec.lineStates(covered: coverage.coveredItems)
        let lines = zip(spec.codeLines, states).enumerated().map { index, pair in
            BugHuntCodeLine(number: index + 1, text: pair.0, state: pair.1)
        }
        return BugHuntPresentation(
            percentText: "\(coverage.percent)%",
            countText: "\(coverage.coveredCount) of \(coverage.total)",
            lines: lines)
    }

    /// The board for `setup`'s bug hunt, or nil on every other kind and on a
    /// bug hunt with no block.
    static func build(
        setup: APITestSetup, activity: ClassActivity, app: Application, on db: any Database
    ) async throws -> BugHuntPresentation? {
        guard activity.kind == .bugHunt, let spec = activity.bugHunt, let setupID = setup.id,
            let manifest = setup.decodedManifest()
        else { return nil }
        let coverage = try await BugHuntCoverage.read(
            testSetupID: setupID, spec: spec, manifest: manifest, on: db)
        var presentation = make(spec: spec, coverage: coverage)
        presentation.recordsCoverage = await declaredContributionSlotCount(setup: setup, app: app) > 0
        return presentation
    }
}
