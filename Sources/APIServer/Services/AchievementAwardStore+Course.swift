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

    /// `grantCourseAchievementsOrLog` for the course of the assignment whose
    /// test setup is `testSetupID`, for the result page.
    static func grantCourseAchievementsOrLog(
        for userID: UUID, courseOfTestSetup testSetupID: String, on db: any Database, logger: Logger
    ) async {
        do {
            guard
                let assignment = try await APIAssignment.query(on: db).filter(\.$testSetupID == testSetupID).first(),
                let course = try await APICourse.find(assignment.courseID, on: db), !course.isArchived
            else { return }
            await grantCourseAchievementsOrLog(for: userID, in: [course], on: db, logger: logger)
        } catch {
            logger.warning(
                "course achievement lookup failed",
                metadata: ["test_setup_id": .string(testSetupID), "error": .string("\(error)")])
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
        let setupIDs = Set(visible.map(\.testSetupID))
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
}
