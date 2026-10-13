// Tests/CoreTests/ActivityBrowserStagingTests.swift
//
// Which activities the browser runner can grade (docs/class-activities.md,
// "Browser grading"): a bundled bot it stages as the worker does; a
// classmate's submission, chosen when a runner claims the job, it cannot.

import Core
import Testing

@Suite struct ActivityBrowserStagingTests {
    @Test(arguments: [
        (ActivityOpponentSource.none, false),
        (.supportFile, false),
        (.paired, false),
        (.champion, true),
        (.classmates, true),
    ])
    func onlyAClaimChosenOpponentNeedsTheWorker(source: ActivityOpponentSource, needsWorker: Bool) {
        #expect(source.opponentNeedsWorker == needsWorker)
    }

    /// Every source answers: a new one cannot reach the browser rule unasked.
    @Test func everySourceAnswers() {
        let workerOnly = ActivityOpponentSource.allCases.filter(\.opponentNeedsWorker)
        #expect(Set(workerOnly) == [.champion, .classmates])
    }

    @Test func aBotChallengeStagesItsChosenBot() {
        #expect(ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py").browserStagedBot == "bot.py")
        #expect(ClassActivity(kind: .beatTheInstructor).browserStagedBot == nil)
    }

    /// A bracket entrant's own submission plays the bot as practice, as on
    /// the worker (`WorkerJobRoutes.pairedJobOpponent`).
    @Test func aBracketEntrantPracticesAgainstTheBot() {
        #expect(ClassActivity(kind: .elimination, opponentFile: "bot.py").browserStagedBot == "bot.py")
        #expect(ClassActivity(kind: .elimination).browserStagedBot == nil)
    }

    @Test(arguments: [ActivityKind.kingOfTheHill, .roundRobin, .testsVersusImplementations, .bestMetric])
    func noOtherKindStagesABotInTheBrowser(kind: ActivityKind) {
        #expect(ClassActivity(kind: kind, opponentFile: "bot.py").browserStagedBot == nil)
    }
}
