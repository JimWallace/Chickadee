// Tests/APITests/Gamification/JobOpponentSelectionTournamentTests.swift
//
// The opponent a worker job stages for a tournament (docs/class-activities.md,
// "Tournaments"), read through `JobOpponentSelection.jobOpponentSet` as the
// claim path reads it. A match job stages the away entrant's snapshotted
// submission and opens its row under the round. It never stages the
// submitter's own work, a superseded submission, or a student of another
// course. A run that is not a match plays the bundled bot or nobody. A base
// URL that cannot carry a download link fails the claim.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct JobOpponentSelectionTournamentTests {

    private static let base = "http://runner-base.test"
    /// `URL(string:)` returns nil for a link under this base: the bracket
    /// of an IPv6 host is never closed.
    private static let unbuildableBase = "http://[::1"

    private func manifest(kind: ActivityKind, opponentFile: String? = nil) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(kind: kind, opponentFile: opponentFile),
            achievements: [
                kind == .roundRobin ? ActivityAuthoring.seededWinnerRecord : ActivityAuthoring.seededTournamentRecord
            ])
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func setup(
        _ app: Application, id: String, kind: ActivityKind = .elimination, opponentFile: String? = nil
    ) async throws -> APITestSetup {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setup = APITestSetup(
            id: id, manifest: try manifest(kind: kind, opponentFile: opponentFile),
            zipPath: app.testSetupsDirectory + "\(id).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: id, title: "Cup \(id)", isOpen: true, on: app)
        return setup
    }

    private func submit(
        _ app: Application, id: String, setupID: String, user: APIUser, minute: Int
    ) async throws -> APISubmission {
        let sub = try await arInsertSubmission(id: id, testSetupID: setupID, userID: try user.requireID(), on: app)
        sub.submittedAt = Date(timeIntervalSince1970: 2_000_000 + Double(minute * 60))
        try await sub.save(on: app.db)
        return sub
    }

    private func enrolledStudent(_ app: Application, _ username: String) async throws -> APIUser {
        let user = try await arInsertStudent(username: username, on: app)
        try await arEnrollStudentInTestCourse(user, on: app)
        return user
    }

    private func opponentSet(
        _ app: Application, setup: APITestSetup, submission: APISubmission, base: String = base
    ) async throws -> (opponent: JobOpponent?, opponents: [JobOpponent]?) {
        let manifest = try #require(setup.decodedManifest())
        return try await JobOpponentSelection.jobOpponentSet(
            manifest: manifest, submission: submission, base: base, on: app.db)
    }

    private func rows(_ app: Application, submissionID: String) async throws -> [APIMatchResult] {
        try await APIMatchResult.query(on: app.db).filter(\.$submissionID == submissionID).all()
    }

    // MARK: - A match job

    /// Four entrants of the course play; a student of another course who
    /// uploaded to the same setup does not enter, and an earlier upload of
    /// an entrant is superseded by their latest. Each match job stages the
    /// away entrant's snapshot, never the home entrant's own work, and opens
    /// one row under the round. A resubmission after the start changes
    /// nothing a match stages.
    @Test func aMatchStagesTheAwayEntrantAndNeverTheSubmitterASupersededUploadOrAnotherCourse()
        async throws
    {
        try await withAssignmentRoutesApp { app in
            let setup = try await setup(app, id: "jos_cup")
            let setupID = try setup.requireID()
            let ann = try await enrolledStudent(app, "jos_ann")
            let ben = try await enrolledStudent(app, "jos_ben")
            let cal = try await enrolledStudent(app, "jos_cal")
            let dee = try await enrolledStudent(app, "jos_dee")
            _ = try await submit(app, id: "jos_ann1", setupID: setupID, user: ann, minute: 1)
            _ = try await submit(app, id: "jos_ben_old", setupID: setupID, user: ben, minute: 2)
            _ = try await submit(app, id: "jos_cal1", setupID: setupID, user: cal, minute: 3)
            _ = try await submit(app, id: "jos_dee1", setupID: setupID, user: dee, minute: 4)
            _ = try await submit(app, id: "jos_ben_new", setupID: setupID, user: ben, minute: 5)

            // A student enrolled only in another course, with an upload to
            // this setup.
            let other = try await makeTestCourse(on: app, code: "JOSOTHER")
            let outsider = try await arInsertStudent(username: "jos_out", on: app)
            try await APICourseEnrollment(
                userID: try outsider.requireID(), courseID: try other.requireID(), role: .student
            ).save(on: app.db)
            _ = try await submit(app, id: "jos_out1", setupID: setupID, user: outsider, minute: 6)

            let run = try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let entrantSubmissions = Set(run.entrants.map(\.submissionID))
            #expect(entrantSubmissions == ["jos_ann1", "jos_cal1", "jos_dee1", "jos_ben_new"])

            // Ben uploads again after the start: the snapshot stands.
            _ = try await submit(app, id: "jos_ben_late", setupID: setupID, user: ben, minute: 7)

            let slots = try await APITournamentMatch.query(on: app.db)
                .filter(\.$tournamentID == (try run.requireID()))
                .sort(\.$position)
                .all()
            let matches = slots.filter { $0.matchSubmissionID != nil }
            #expect(matches.count == 2)
            var staged: Set<String> = []
            for slot in matches {
                let match = try #require(try await APISubmission.find(slot.matchSubmissionID ?? "", on: app.db))
                let home = try #require(run.entrants.first { $0.seed == slot.homeSeed })
                let away = try #require(run.entrants.first { $0.seed == slot.awaySeed })

                let set = try await opponentSet(app, setup: setup, submission: match)
                #expect(set.opponents == nil)
                let opponent = try #require(set.opponent)
                let stagedID = try #require(opponent.submissionID)
                staged.insert(stagedID)

                #expect(stagedID == away.submissionID)
                #expect(stagedID != home.submissionID)
                #expect(!["jos_ben_old", "jos_ben_late", "jos_out1"].contains(stagedID))
                #expect(opponent.supportFile == nil)
                #expect(
                    opponent.submissionURL?.absoluteString
                        == "\(Self.base)/api/v1/worker/submissions/\(stagedID)/download")
                let awaySubmission = try #require(try await APISubmission.find(stagedID, on: app.db))
                #expect(opponent.submissionFilename == awaySubmission.filename)
                let matchID = try match.requireID()
                #expect(
                    opponent.matchSeed
                        == JobOpponent.matchSeed(
                            submissionID: matchID, opponentIdentity: JobOpponent.submissionIdentity(stagedID)))

                let opened = try await rows(app, submissionID: matchID)
                #expect(opened.count == 1)
                #expect(opened.first?.opponentSubmissionID == stagedID)
                #expect(opened.first?.round == slot.round)
                #expect(opened.first?.completedAt == nil)
            }
            // Between them the two matches stage two distinct entrants.
            #expect(staged.count == 2)
            #expect(staged.isSubset(of: entrantSubmissions))
        }
    }

    /// A re-claim of the same match reopens its one row rather than opening
    /// a second.
    @Test func aReclaimOfAMatchKeepsOneRow() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await setup(app, id: "jos_reclaim")
            let setupID = try setup.requireID()
            for (index, name) in ["jos_r1", "jos_r2"].enumerated() {
                let user = try await enrolledStudent(app, name)
                _ = try await submit(app, id: "\(name)_s", setupID: setupID, user: user, minute: index)
            }
            let run = try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let slot = try #require(
                try await APITournamentMatch.query(on: app.db)
                    .filter(\.$tournamentID == (try run.requireID()))
                    .filter(\.$matchSubmissionID != nil)
                    .first())
            let match = try #require(try await APISubmission.find(slot.matchSubmissionID ?? "", on: app.db))

            let first = try await opponentSet(app, setup: setup, submission: match)
            let second = try await opponentSet(app, setup: setup, submission: match)

            #expect(first.opponent?.submissionID == "jos_r2_s")
            #expect(second.opponent?.submissionID == "jos_r2_s")
            #expect(try await rows(app, submissionID: try match.requireID()).count == 1)
        }
    }

    // MARK: - Runs that are not a match

    /// A student's own upload on a tournament assignment plays the bundled
    /// bot as practice, with no row. A validation run plays nobody, even
    /// with a bot chosen, and opens no row either.
    @Test func aRunThatIsNotAMatchPlaysTheBotOrNobodyAndOpensNoRow() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await setup(app, id: "jos_practice", opponentFile: "bot.py")
            let setupID = try setup.requireID()
            let student = try await enrolledStudent(app, "jos_prac")
            let own = try await submit(app, id: "jos_prac1", setupID: setupID, user: student, minute: 1)

            let practice = try await opponentSet(app, setup: setup, submission: own)
            let bot = try #require(practice.opponent)
            #expect(bot.supportFile == "bot.py")
            #expect(bot.submissionID == nil)
            #expect(
                bot.matchSeed
                    == JobOpponent.matchSeed(
                        submissionID: "jos_prac1", opponentIdentity: JobOpponent.supportFileIdentity("bot.py")))
            #expect(practice.opponents == nil)
            #expect(try await rows(app, submissionID: "jos_prac1").isEmpty)

            let validation = APISubmission(
                id: "jos_val1", testSetupID: setupID, zipPath: app.submissionsDirectory + "jos_val1.zip",
                attemptNumber: 1, status: "complete", userID: try student.requireID(),
                kind: APISubmission.Kind.validation)
            try await validation.save(on: app.db)
            let staff = try await opponentSet(app, setup: setup, submission: validation)
            #expect(staff.opponent == nil)
            #expect(staff.opponents == nil)
            #expect(try await rows(app, submissionID: "jos_val1").isEmpty)
        }
    }

    /// With no bot chosen, a student's own upload on a tournament assignment
    /// plays nobody.
    @Test func aStudentUploadWithNoBotPlaysNobody() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await setup(app, id: "jos_nobot")
            let student = try await enrolledStudent(app, "jos_nobot_u")
            let own = try await submit(
                app, id: "jos_nobot1", setupID: try setup.requireID(), user: student, minute: 1)

            let set = try await opponentSet(app, setup: setup, submission: own)
            #expect(set.opponent == nil)
            #expect(set.opponents == nil)
            #expect(try await rows(app, submissionID: "jos_nobot1").isEmpty)
        }
    }

    // MARK: - A base URL that cannot carry a link

    /// The tournament claim fails when the opponent's download link cannot
    /// be built. The row is already open by then, under the round.
    @Test func aMatchWithAnUnbuildableBaseFailsTheClaim() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await setup(app, id: "jos_badurl")
            let setupID = try setup.requireID()
            for (index, name) in ["jos_b1", "jos_b2"].enumerated() {
                let user = try await enrolledStudent(app, name)
                _ = try await submit(app, id: "\(name)_s", setupID: setupID, user: user, minute: index)
            }
            let run = try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let slot = try #require(
                try await APITournamentMatch.query(on: app.db)
                    .filter(\.$tournamentID == (try run.requireID()))
                    .filter(\.$matchSubmissionID != nil)
                    .first())
            let match = try #require(try await APISubmission.find(slot.matchSubmissionID ?? "", on: app.db))

            do {
                _ = try await opponentSet(app, setup: setup, submission: match, base: Self.unbuildableBase)
                Issue.record("an unbuildable download URL must fail the claim")
            } catch let error as WorkerJobError {
                guard case .internalInconsistency(let reason) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(reason.contains("opponent download URL"))
                #expect(reason.contains(Self.unbuildableBase))
            }
            let opened = try await rows(app, submissionID: try match.requireID())
            #expect(opened.map(\.opponentSubmissionID) == ["jos_b2_s"])
            #expect(opened.first?.round == 1)
        }
    }

    /// A round-robin claim plans its classmates in order and stops at the
    /// first link it cannot build: the rows up to that classmate open, then
    /// the claim fails.
    @Test func aRoundRobinWithAnUnbuildableBaseOpensTheFirstRowAndFails() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await setup(app, id: "jos_robin", kind: .roundRobin)
            let setupID = try setup.requireID()
            var own: APISubmission?
            for (index, name) in ["jos_ra", "jos_rb", "jos_rc"].enumerated() {
                let user = try await enrolledStudent(app, name)
                let sub = try await submit(app, id: "\(name)_s", setupID: setupID, user: user, minute: index)
                if own == nil { own = sub }
            }
            let challenger = try #require(own)

            do {
                _ = try await opponentSet(app, setup: setup, submission: challenger, base: Self.unbuildableBase)
                Issue.record("an unbuildable download URL must fail the claim")
            } catch let error as WorkerJobError {
                guard case .internalInconsistency(let reason) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(reason.contains("classmate download URL"))
            }
            let opened = try await rows(app, submissionID: "jos_ra_s")
            // Classmates are planned in submission-ID order.
            #expect(opened.map(\.opponentSubmissionID) == ["jos_rb_s"])
        }
    }
}
