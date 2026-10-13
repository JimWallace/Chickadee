// APIServer/Routes/Web/ArenaMatchResponse.swift
//
// The JSON the projector arena reads for its next match
// (docs/class-activities.md, "Projector arena").

import Vapor

/// One match for the arena to play. The two entrants are named by seed only:
/// the page is projected, and the bracket names them by handle.
struct ArenaMatchResponse: Content, Equatable {
    /// Download it from `/testsetups/:id/arena/submissions/:matchSubmissionID`
    /// as the home entrant's upload, and post the result against it.
    let matchSubmissionID: String
    let homeFilename: String?
    /// Download it the same way; it is staged under `opponent/`.
    let awaySubmissionID: String
    let awayFilename: String?
    let round: Int
    let position: Int
    let homeSeed: Int
    let awaySeed: Int
    /// `CHICKADEE_MATCH_SEED` for the match, as a runner would set it.
    let matchSeed: String

    init(_ match: ArenaMatch) {
        matchSubmissionID = match.matchSubmissionID
        homeFilename = match.homeFilename
        awaySubmissionID = match.awaySubmissionID
        awayFilename = match.awayFilename
        round = match.round
        position = match.position
        homeSeed = match.homeSeed
        awaySeed = match.awaySeed
        matchSeed = match.matchSeed
    }
}
