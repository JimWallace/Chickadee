import Core
import Foundation
import Vapor

/// The bot a browser-graded run plays: the file to stage, and the match seed.
///
/// The native worker derives the seed from the submission ID
/// (`JobOpponent.matchSeed`), which the browser does not have until its
/// result is stored. Each submission's ID is new, so each worker match gets a
/// new seed. The browser gets the same behaviour from a new random nonce in
/// place of the ID: a new seed on every run, in the same 64-hex shape.
struct BrowserRunnerOpponent: Content, Equatable {
    /// The bot's file name, as it is in the setup.
    let file: String
    let matchSeed: String

    init(botFile: String, nonce: String = UUID().uuidString) {
        self.file = botFile
        self.matchSeed = JobOpponent.matchSeed(
            submissionID: "browser:\(nonce)",
            opponentIdentity: JobOpponent.supportFileIdentity(botFile))
    }
}
