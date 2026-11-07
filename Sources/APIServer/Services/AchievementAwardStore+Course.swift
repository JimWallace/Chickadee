// APIServer/Services/AchievementAwardStore+Course.swift
//
// Evaluates a course's achievements for one student and stores the ones
// earned (docs/achievement-rewards.md, decision 7, slice S3). It runs when
// the student's own result page or account page loads, never while a result
// is written, so an award can never fail a grade. A stored award is kept.

import Core
import Fluent
import Foundation
import Logging

extension AchievementAwardStore {

    /// Stores each achievement of `course` that `userID` has earned and not
    /// stored yet, and returns the rows this call wrote. When every
    /// achievement of the course is stored already, nothing more is read.
    @discardableResult
    static func grantCourseAchievements(
        for userID: UUID, in course: APICourse, on db: any Database
    ) async throws -> [APIAchievementAward] {
        let definitions = course.courseAchievements
        guard !definitions.isEmpty else { return [] }
        let ownerID = try course.requireID().uuidString
        let stored = try await APIAchievementAward.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$level == AchievementLevel.course.rawValue)
            .filter(\.$ownerID == ownerID)
            .all()
        let storedIDs = Set(stored.map(\.achievementID))
        let pending = definitions.filter { !storedIDs.contains($0.id) }
        guard !pending.isEmpty else { return [] }
        let progress = try await courseProgress(for: userID, in: course, on: db)
        return try await storeSatisfied(pending, by: progress, userID: userID, ownerID: ownerID, on: db)
    }

    /// Stores each of `pending` that `progress` satisfies, as `userID`'s
    /// course-level award, and returns the rows written. A row another
    /// request stored first is skipped.
    @discardableResult
    private static func storeSatisfied(
        _ pending: [Achievement], by progress: CourseProgress, userID: UUID, ownerID: String, on db: any Database
    ) async throws -> [APIAchievementAward] {
        var written: [APIAchievementAward] = []
        for achievement in pending where achievement.isSatisfied(by: progress) {
            let row = APIAchievementAward(
                userID: userID, level: .course, ownerID: ownerID, achievementID: achievement.id,
                submissionID: nil, label: achievement.name, detail: achievement.detail)
            do {
                try await row.create(on: db)
                written.append(row)
            } catch  where isInsertConflict(error) {
                continue
            }
        }
        return written
    }

    /// `grantCourseAchievementsOrLog(for:in:)` for every student of
    /// `userIDs` in `course`, for the staff Recompute action. What is the
    /// same for every student is read once: the course's definitions, the
    /// assignments students can see, the stored course awards and the
    /// assignment-level awards. Each student's graded work is still read on
    /// its own, and a failure for one student is logged and the rest go on.
    /// A failure of the shared reads is logged once, and no student is
    /// granted; the next Recompute or page load grants again.
    static func grantCourseAchievementsOrLog(
        forStudents userIDs: [UUID], in course: APICourse, on db: any Database, logger: Logger,
        now: Date = Date()
    ) async {
        let definitions = course.courseAchievements
        guard !definitions.isEmpty, !userIDs.isEmpty else { return }
        let ownerID: String
        var pendingByUser: [(userID: UUID, pending: [Achievement])] = []
        var visible: (assignments: [CourseProgress.Assignment], setupIDs: Set<String>) = ([], [])
        var awardsByUser: [UUID: [CourseProgress.Award]] = [:]
        do {
            ownerID = try course.requireID().uuidString
            var storedByUser: [UUID: Set<String>] = [:]
            for chunk in chunkedForInFilter(userIDs) {
                let rows = try await APIAchievementAward.query(on: db)
                    .filter(\.$userID ~~ chunk)
                    .filter(\.$level == AchievementLevel.course.rawValue)
                    .filter(\.$ownerID == ownerID)
                    .all()
                for row in rows { storedByUser[row.userID, default: []].insert(row.achievementID) }
            }
            for userID in userIDs {
                let stored = storedByUser[userID] ?? []
                let pending = definitions.filter { !stored.contains($0.id) }
                if !pending.isEmpty { pendingByUser.append((userID, pending)) }
            }
            guard !pendingByUser.isEmpty else { return }
            visible = try await visibleAssignments(of: course, on: db, now: now)
            if !visible.setupIDs.isEmpty {
                for chunk in chunkedForInFilter(pendingByUser.map(\.userID)) {
                    let rows = try await APIAchievementAward.query(on: db)
                        .filter(\.$userID ~~ chunk)
                        .filter(\.$level == AchievementLevel.assignment.rawValue)
                        .filter(\.$ownerID ~~ Array(visible.setupIDs))
                        .all()
                    for row in rows {
                        awardsByUser[row.userID, default: []].append(
                            CourseProgress.Award(testSetupID: row.ownerID, achievementID: row.achievementID))
                    }
                }
            }
        } catch {
            logger.warning(
                "course achievement recompute failed",
                metadata: ["course_id": .string(course.id?.uuidString ?? ""), "error": .string("\(error)")])
            return
        }
        for (userID, pending) in pendingByUser {
            do {
                let graded = try await WardrobeUnlockStore.graded(for: userID, inTestSetups: visible.setupIDs, on: db)
                let progress = CourseProgress(
                    assignments: visible.assignments, graded: graded, awards: awardsByUser[userID] ?? [])
                try await storeSatisfied(pending, by: progress, userID: userID, ownerID: ownerID, on: db)
            } catch {
                logger.warning(
                    "course achievement award write failed",
                    metadata: ["course_id": .string(ownerID), "error": .string("\(error)")])
            }
        }
    }

    /// `grantCourseAchievements` for every course in `courses`, for a page
    /// that must render whatever happens: a failure is logged and the page
    /// goes on. The next load grants again.
    static func grantCourseAchievementsOrLog(
        for userID: UUID, in courses: [APICourse], on db: any Database, logger: Logger
    ) async {
        for course in courses where !course.courseAchievements.isEmpty {
            do {
                try await grantCourseAchievements(for: userID, in: course, on: db)
            } catch {
                logger.warning(
                    "course achievement award write failed",
                    metadata: ["course_id": .string(course.id?.uuidString ?? ""), "error": .string("\(error)")])
            }
        }
    }

    /// Removes every course-level award of the course `courseID`. Course
    /// deletion calls this, because the rows name the course's students.
    static func deleteCourseAwards(forCourse courseID: UUID, on db: any Database) async throws {
        try await APIAchievementAward.query(on: db)
            .filter(\.$level == AchievementLevel.course.rawValue)
            .filter(\.$ownerID == courseID.uuidString)
            .delete()
    }

    /// What `userID`'s work in `course` shows: the assignments students can
    /// see, the student's graded submissions to them, and the student's
    /// assignment-level awards on them.
    static func courseProgress(
        for userID: UUID, in course: APICourse, on db: any Database, now: Date = Date()
    ) async throws -> CourseProgress {
        let (assignments, setupIDs) = try await visibleAssignments(of: course, on: db, now: now)
        let graded = try await WardrobeUnlockStore.graded(for: userID, inTestSetups: setupIDs, on: db)
        let awards =
            setupIDs.isEmpty
            ? []
            : try await APIAchievementAward.query(on: db)
                .filter(\.$userID == userID)
                .filter(\.$level == AchievementLevel.assignment.rawValue)
                .filter(\.$ownerID ~~ Array(setupIDs))
                .all()
        return CourseProgress(
            assignments: assignments, graded: graded,
            awards: awards.map { CourseProgress.Award(testSetupID: $0.ownerID, achievementID: $0.achievementID) })
    }

    /// The course-wide half of `courseProgress`, the same for every student:
    /// the assignments students can see at `now`, and their setup IDs.
    private static func visibleAssignments(
        of course: APICourse, on db: any Database, now: Date
    ) async throws -> (assignments: [CourseProgress.Assignment], setupIDs: Set<String>) {
        let courseID = try course.requireID()
        let visible = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
            .filter { assignmentVisibleToStudentByState($0, now: now) }
        let assignments = visible.map { assignment in
            CourseProgress.Assignment(
                testSetupID: assignment.testSetupID, publicID: assignment.publicID,
                courseSectionID: assignment.sectionID?.uuidString, concept: assignment.concept)
        }
        return (assignments, Set(visible.map(\.testSetupID)))
    }
}
