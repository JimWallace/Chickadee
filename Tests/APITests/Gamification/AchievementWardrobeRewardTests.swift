// Tests/APITests/Gamification/AchievementWardrobeRewardTests.swift
//
// A wardrobe item as an assignment achievement's reward
// (docs/achievement-rewards.md, decision 4, slice S2): the editor's validator
// accepts it on an individual row only and only for a grantable item, the
// result page grants it once with the achievement's name, the account page
// says how it was earned, and a student who already holds the item earns
// nothing new.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct AchievementWardrobeRewardTests {

    private static let paintedID = "painted_tile"
    private static let paintedName = "Painted a tile"

    /// A manifest whose one curated achievement grants the cross-fade ring
    /// for any graded submission.
    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],\
        "timeLimitSeconds":10,"builtInAchievementsSeeded":true,"achievements":[{"id":"\(paintedID)",\
        "name":"\(paintedName)","scope":"individual","conditions":[],"match":"all",\
        "reward":{"type":"wardrobe","label":"\(paintedName)","item":"border.crossfade"}}]}
        """

    private func gradeSubmission(id: String, setupID: String, on app: Application) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            try await wrInsertSetup(id: setupID, manifest: Self.manifest, on: app)
            try await wrInsertAssignment(testSetupID: setupID, title: "Paint", isOpen: true, on: app)
        }
        try await wrInsertSubmission(id: id, testSetupID: setupID, userID: student.requireID(), on: app)
        try await wrInsertResult(
            submissionID: id, outcomes: [wrMakeOutcome(name: "test.sh", tier: .pub, status: .pass)], on: app)
    }

    private func row(_ fields: (inout AchievementRow) -> Void) -> AchievementRow {
        var row = AchievementRow(name: Self.paintedName, scope: "individual", conditions: [])
        fields(&row)
        return row
    }

    // MARK: - The validator

    @Test func anIndividualRowGrantsAGrantableItem() throws {
        let achievement = try AchievementsEditing.achievement(
            from: row {
                $0.rewardType = "wardrobe"
                $0.rewardItem = WardrobeItem.crossFadeRing.rawValue
            })
        #expect(achievement.reward.type == .wardrobe)
        #expect(achievement.reward.wardrobeItem == .crossFadeRing)
        // Hidden until earned: it is never a badge.
        #expect(!achievement.isAuthorableIndividualBadge)
        #expect(!achievement.isPerSubmissionBadge)
        // The row reads back as it was written.
        let back = AchievementsEditing.row(from: achievement)
        #expect(back.rewardType == "wardrobe")
        #expect(back.rewardItem == "border.crossfade")
    }

    @Test(arguments: [nil, "", "border.twotone", "border.quantumcats", "border.nothing"])
    func anItemThatIsNotGrantableIsRefused(item: String?) {
        #expect(throws: AppError.self) {
            try AchievementsEditing.achievement(
                from: row {
                    $0.rewardType = "wardrobe"
                    $0.rewardItem = item
                })
        }
    }

    @Test func aRecordAndAClassGoalCannotGrantAnItem() {
        #expect(throws: AppError.self) {
            try AchievementsEditing.achievement(
                from: row {
                    $0.scope = "record"
                    $0.recordDimension = "firstToSolve"
                    $0.rewardType = "wardrobe"
                    $0.rewardItem = "border.crossfade"
                })
        }
        #expect(throws: AppError.self) {
            try AchievementsEditing.achievement(
                from: row {
                    $0.scope = "classWide"
                    $0.classPercent = 80
                    $0.rewardType = "wardrobe"
                    $0.rewardItem = "border.crossfade"
                })
        }
    }

    @Test func aCourseAchievementCannotGrantAnItem() {
        #expect(throws: AppError.self) {
            try AchievementsEditing.achievement(
                from: row {
                    $0.conditions = [ConditionRow(signal: "assignmentsGraded", comparator: "atLeast", value: 1)]
                    $0.rewardType = "wardrobe"
                    $0.rewardItem = "border.crossfade"
                }, at: .course)
        }
    }

    @Test func anUnknownRewardTypeIsRefusedAndTheScopesOwnIsIgnored() throws {
        #expect(throws: AppError.self) {
            try AchievementsEditing.achievement(from: row { $0.rewardType = "trophy" })
        }
        let badge = try AchievementsEditing.achievement(from: row { $0.rewardType = "badge" })
        #expect(badge.reward.type == .badge)
        let record = try AchievementsEditing.achievement(
            from: row {
                $0.scope = "record"
                $0.recordDimension = "fastest"
                $0.rewardType = "title"
            })
        #expect(record.reward.type == .title)
    }

    /// A hand-authored manifest naming an item no achievement may grant is
    /// refused on save, so it cannot sit there granting nothing.
    @Test func aManifestNamingARuleItemIsRefusedOnSave() {
        let achievement = Achievement(
            id: "x", name: "X", scope: .individual,
            reward: AchievementReward(type: .wardrobe, label: "X", item: WardrobeItem.twoToneRing.rawValue))
        #expect(throws: AppError.self) {
            try AchievementsEditing.validate([achievement], againstManifest: Self.manifest)
        }
    }

    // MARK: - The grant

    @Test func theResultPageGrantsTheItemOnceWithTheAchievementsName() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "awr_s1", setupID: "awr_a", on: app)

            let html = try await getHTML("/submissions/awr_s1", cookie: cookie, on: app)
            #expect(html.contains(#"id="earned-toast""#))
            #expect(html.contains("Cross-fade"))
            #expect(html.contains("Earned for “\(Self.paintedName)”."))

            let student = try await wrStudentUser(on: app)
            let userID = try student.requireID()
            let unlock = try #require(
                try await APIWardrobeUnlock.query(on: app.db)
                    .filter(\.$userID == userID)
                    .filter(\.$item == WardrobeItem.crossFadeRing.rawValue)
                    .first())
            #expect(unlock.label == Self.paintedName)
            #expect(unlock.source == "achievement:assignment:awr_a:\(Self.paintedID)")
            let awards = try await AchievementAwardStore.awards(for: userID, on: app.db)
            #expect(awards.map(\.achievementID).contains(Self.paintedID))

            // A grant happens once, so a reload grants nothing new.
            let again = try await getHTML("/submissions/awr_s1", cookie: cookie, on: app)
            #expect(!again.contains("Earned for “\(Self.paintedName)”."))
            let count = try await APIWardrobeUnlock.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$item == WardrobeItem.crossFadeRing.rawValue)
                .count()
            #expect(count == 1)

            // The account page offers the ring and says how it was earned.
            let account = try await getHTML("/account", cookie: cookie, on: app)
            #expect(account.contains(#"name="border" value="crossfade""#))
            #expect(account.contains("Cross-fade: earned for “\(Self.paintedName)”."))
        }
    }

    @Test func aStudentWhoHoldsTheItemEarnsNothingNew() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await APIWardrobeUnlock(
                userID: student.requireID(), item: .crossFadeRing, source: "achievement:assignment:other:x",
                label: "Elsewhere"
            ).save(on: app.db)
            try await gradeSubmission(id: "awr_s2", setupID: "awr_b", on: app)

            let html = try await getHTML("/submissions/awr_s2", cookie: cookie, on: app)
            #expect(!html.contains("Earned for “\(Self.paintedName)”."))
            let unlocks = try await APIWardrobeUnlock.query(on: app.db)
                .filter(\.$userID == student.requireID())
                .filter(\.$item == WardrobeItem.crossFadeRing.rawValue)
                .all()
            #expect(unlocks.map(\.label) == ["Elsewhere"])
        }
    }

    /// The store: two grants of one achievement write one award and one item.
    @Test func twoGrantsWriteOneRow() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let userID = try student.requireID()
            let achievement = Achievement(
                id: Self.paintedID, name: Self.paintedName, scope: .individual,
                reward: AchievementReward(
                    type: .wardrobe, label: Self.paintedName, item: WardrobeItem.spectrumRing.rawValue))
            let first = try await AchievementAwardStore.grantWardrobeRewards(
                [achievement], testSetupID: "awr_c", submissionID: "s1", earnedBy: userID, on: app.db)
            let second = try await AchievementAwardStore.grantWardrobeRewards(
                [achievement], testSetupID: "awr_c", submissionID: "s2", earnedBy: userID, on: app.db)
            #expect(first == [AchievementAwardStore.GrantedItem(item: .spectrumRing, label: Self.paintedName)])
            #expect(second.isEmpty)
            #expect(try await AchievementAwardStore.awards(for: userID, on: app.db).count == 1)
            #expect(
                try await WardrobeUnlockStore.grantLabels(for: userID, on: app.db) == [.spectrumRing: Self.paintedName])
        }
    }
}
