// APIServer/Services/JobOpponentSelection.swift
//
// The opponents a worker job plays in a class activity: the bundled bot,
// the hill champion, the tournament match, or the classmates of a round
// robin. Moved from WorkerJobRoutes.swift (#2774) with no behaviour change.
// `WorkerJobRoutes.buildJobPayload` calls `jobOpponentSet` once per job.

import Core
import Fluent
import Foundation
import Vapor

enum JobOpponentSelection {
    /// Both opponent fields of a job, from one read of the activity: the
    /// single opponent of a bot, hill or tournament match, or the classmate
    /// list of a matrix job. The classmates are queried ONCE here and handed
    /// to both builders; each used to call `chooseClassmates` itself, inside
    /// the serialized claim section (#1750).
    static func jobOpponentSet(
        manifest: TestProperties, submission: APISubmission, base: String, on db: any Database
    ) async throws(WorkerJobError) -> (opponent: JobOpponent?, opponents: [JobOpponent]?) {
        guard let activity = manifest.activity, activity.stagesAnOpponent, let submissionID = submission.id
        else { return (nil, nil) }
        if playsPractice(activity: activity, submission: submission) {
            return (practiceOpponent(activity: activity, submissionID: submissionID), nil)
        }
        var classmates: [ChosenOpponent] = []
        if activity.kind.opponentSource == .classmates {
            do {
                // A re-claim (retest) of a STANDINGS kind replaces the whole
                // result: rows from an earlier claim against classmates who
                // have since resubmitted would otherwise stay completed and
                // inflate the standings (#1744). A UNION kind keeps them: a
                // kill stays with the tester after the target fixes the
                // fault, and the union counts distinct students, so an old
                // row cannot count twice (#2187).
                if activity.kind.aggregation == .standings {
                    try await voidCompletedMatrixRows(submissionID: submissionID, on: db)
                }
                classmates = try await chooseClassmates(for: submission, activity: activity, on: db)
            } catch {
                throw WorkerJobError.internalInconsistency(
                    reason: "Could not choose the classmates for \(submissionID): \(error)")
            }
        }
        return (
            try await jobOpponent(
                activity: activity, submission: submission, base: base, classmates: classmates, on: db),
            try await jobOpponents(
                activity: activity, classmates: classmates, submission: submission, base: base, on: db)
        )
    }

    /// Whether a run plays practice instead of the class: a run that is not
    /// a student's own entry (a validation run or a class corpus run) on a
    /// kind that plays the class (classmates or the champion). Such a run
    /// plays the bundled bot, or nobody, and opens no match row.
    ///
    /// It used to play the live class: a re-validation of a large round
    /// robin cost one suite run per student, its verdict depended on the
    /// students' code, and the rows it opened never completed, because the
    /// class effects read only a `.student` result (#2188).
    static func playsPractice(activity: ClassActivity, submission: APISubmission) -> Bool {
        let notAnEntry = [
            APISubmission.Kind.validation, APISubmission.Kind.starterValidation, APISubmission.Kind.classAggregate,
        ].contains(submission.kind)
        let source = activity.kind.opponentSource
        return notAnEntry && (source == .classmates || source == .champion)
    }

    /// The bundled bot as a practice opponent, with its usual seed; nil when
    /// the activity names no bot.
    static func practiceOpponent(activity: ClassActivity, submissionID: String) -> JobOpponent? {
        activity.opponentFile.map { file in
            JobOpponent(
                supportFile: file,
                matchSeed: JobOpponent.matchSeed(
                    submissionID: submissionID, opponentIdentity: JobOpponent.supportFileIdentity(file)))
        }
    }

    /// The opponents a MATRIX job plays (round robin), each with its own open
    /// match row; nil for every other job. With no classmate yet the job is
    /// built like a bot match through `jobOpponent`, so this returns nil
    /// then too. `classmates` is the list `jobOpponentSet` chose.
    static func jobOpponents(
        activity: ClassActivity, classmates: [ChosenOpponent], submission: APISubmission, base: String,
        on db: any Database
    ) async throws(WorkerJobError) -> [JobOpponent]? {
        guard activity.kind.opponentSource == .classmates, !classmates.isEmpty,
            let submissionID = submission.id
        else { return nil }
        do {
            var opponents: [JobOpponent] = []
            for chosen in classmates {
                guard let classmate = chosen.champion, let classmateID = classmate.id else { continue }
                let seed = JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: chosen.identity)
                try await openMatch(
                    testSetupID: submission.testSetupID, submissionID: submissionID,
                    opponent: chosen, seed: seed, on: db)
                guard let url = URL(string: "\(base)/api/v1/worker/submissions/\(classmateID)/download") else {
                    throw WorkerJobError.internalInconsistency(
                        reason: "Failed to build a classmate download URL from base=\(base)")
                }
                opponents.append(
                    JobOpponent(
                        supportFile: nil, matchSeed: seed, submissionID: classmateID,
                        submissionURL: url, submissionFilename: classmate.filename))
            }
            return opponents
        } catch let error as WorkerJobError {
            throw error
        } catch {
            throw WorkerJobError.internalInconsistency(
                reason: "Could not open the matches for \(submissionID): \(error)")
        }
    }

    /// The opponent a match job stages (docs/class-activities.md), or nil for
    /// an ordinary run — and for a bot activity whose bot is not chosen yet,
    /// which grades as it did before the primitive existed. Read from the
    /// FULL manifest: `runnerSanitized()` strips the activity block, which is
    /// why the runner learns this from the job.
    ///
    /// For king of the hill this also OPENS the match row (`openMatch`), so
    /// the result path knows which opponent the job played. A database error
    /// there is the claim's error: a match graded with no row could never
    /// move the hill, which would read as a loss.
    static func jobOpponent(
        activity: ClassActivity, submission: APISubmission, base: String, classmates: [ChosenOpponent],
        on db: any Database
    ) async throws(WorkerJobError) -> JobOpponent? {
        guard activity.stagesAnOpponent, let submissionID = submission.id else { return nil }
        switch activity.kind.opponentSource {
        case .none:
            return nil
        case .paired:
            return try await pairedJobOpponent(activity: activity, submission: submission, base: base, on: db)
        case .classmates:
            // With classmates to play, `jobOpponents` carries them. With
            // none yet, the bot stands in as a single opponent — one open
            // row, completed from the collection's match entry.
            guard classmates.isEmpty else { return nil }
            do {
                let bot = ChosenOpponent(
                    champion: nil,
                    identity: activity.opponentFile.map(JobOpponent.supportFileIdentity)
                        ?? JobOpponent.noOpponentIdentity)
                let seed = JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: bot.identity)
                try await openMatch(
                    testSetupID: submission.testSetupID, submissionID: submissionID,
                    opponent: bot, seed: seed, on: db)
                guard activity.opponentFile != nil else { return nil }
                return JobOpponent(supportFile: activity.opponentFile, matchSeed: seed)
            } catch {
                throw WorkerJobError.internalInconsistency(
                    reason: "Could not open the match for \(submissionID): \(error)")
            }
        case .supportFile:
            return JobOpponent(
                supportFile: activity.opponentFile,
                matchSeed: JobOpponent.matchSeed(
                    submissionID: submissionID,
                    opponentIdentity: JobOpponent.supportFileIdentity(activity.opponentFile)))
        case .champion:
            do {
                let chosen = try await chooseOpponent(for: submission, activity: activity, on: db)
                let seed = JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: chosen.identity)
                try await openMatch(
                    testSetupID: submission.testSetupID, submissionID: submissionID,
                    opponent: chosen, seed: seed, on: db)
                if let champion = chosen.champion, let championID = champion.id {
                    guard
                        let url = URL(
                            string: "\(base)/api/v1/worker/submissions/\(championID)/download")
                    else {
                        throw WorkerJobError.internalInconsistency(
                            reason: "Failed to build the champion download URL from base=\(base)")
                    }
                    return JobOpponent(
                        supportFile: nil, matchSeed: seed, submissionID: championID,
                        submissionURL: url, submissionFilename: champion.filename)
                }
                // The bot holds the hill, or nobody does: the job carries the
                // bot when there is one, and no opponent at all otherwise —
                // the row is open either way, so a passing match takes it.
                guard activity.opponentFile != nil else { return nil }
                return JobOpponent(supportFile: activity.opponentFile, matchSeed: seed)
            } catch let error as WorkerJobError {
                throw error
            } catch {
                throw WorkerJobError.internalInconsistency(
                    reason: "Could not open the match for \(submissionID): \(error)")
            }
        }
    }

    /// The opponent of a tournament match (docs/class-activities.md,
    /// "Tournaments"): the entrant it is paired with, staged on the hill's
    /// single-submission contract, with its row opened under the round. A
    /// student's own submission on such an assignment plays the bundled
    /// bot, if one is chosen, as practice, with no row.
    static func pairedJobOpponent(
        activity: ClassActivity, submission: APISubmission, base: String, on db: any Database
    ) async throws(WorkerJobError) -> JobOpponent? {
        guard let submissionID = submission.id else { return nil }
        do {
            guard let paired = try await pairedOpponent(for: submission, on: db) else {
                guard submission.kind == APISubmission.Kind.student, let file = activity.opponentFile else {
                    return nil
                }
                return JobOpponent(
                    supportFile: file,
                    matchSeed: JobOpponent.matchSeed(
                        submissionID: submissionID, opponentIdentity: JobOpponent.supportFileIdentity(file)))
            }
            guard let awayID = paired.away.id else { return nil }
            let chosen = ChosenOpponent(champion: paired.away, identity: JobOpponent.submissionIdentity(awayID))
            let seed = JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: chosen.identity)
            try await openMatch(
                testSetupID: submission.testSetupID, submissionID: submissionID,
                opponent: chosen, seed: seed, round: paired.slot.round, on: db)
            guard let url = URL(string: "\(base)/api/v1/worker/submissions/\(awayID)/download") else {
                throw WorkerJobError.internalInconsistency(
                    reason: "Failed to build the opponent download URL from base=\(base)")
            }
            return JobOpponent(
                supportFile: nil, matchSeed: seed, submissionID: awayID,
                submissionURL: url, submissionFilename: paired.away.filename)
        } catch let error as WorkerJobError {
            throw error
        } catch {
            throw WorkerJobError.internalInconsistency(
                reason: "Could not open the tournament match for \(submissionID): \(error)")
        }
    }
}
