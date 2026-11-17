// APIServer/Services/UsageCourseFacts.swift
//
// The per-course numbers `UsageStatisticsBuilder` gathers, and the fold that
// turns a set of them into `UsageTotals`. People are held as user-ID sets so a
// person in two courses counts once in a total; the sets never leave this
// file's callers (the report holds counts only).

import Core
import Foundation

/// One course offering placed in a term, with everything counted for it.
struct UsageCourseFacts: Sendable {
    let courseID: UUID
    let code: String
    let key: String
    let name: String
    let term: AcademicTerm
    let termInferred: Bool
    let archived: Bool
    let usesBrightSpace: Bool
    let usesLTI: Bool
    let usesAIFeedback: Bool

    var students: Set<UUID> = []
    var instructors: Set<UUID> = []
    var teachingAssistants: Set<UUID> = []
    /// Everyone who made a student submission or opened a lab, staff
    /// included; `activeStudents` takes the staff out.
    var participants: Set<UUID> = []
    var studentSubmissionsByUser: [UUID: Int] = [:]
    var studentSubmissions = 0
    var studentByStatus: [String: Int] = [:]
    var studentBySource: [String: Int] = [:]
    var validationSubmissions = 0
    var labParticipations = 0
    var assignments = 0
    var assignmentsByType: [String: Int] = [:]
    var assignmentsByLanguage: [String: Int] = [:]
    var contentItems = 0
    var aiFeedbackReleased = 0
    var tournamentsRun = 0

    /// Participants who are not course staff.
    var activeStudents: Set<UUID> {
        participants.subtracting(instructors).subtracting(teachingAssistants)
    }

    var usedGitHubSubmissions: Bool {
        (studentBySource[SubmissionSource.github.rawValue] ?? 0) > 0
    }

    /// The course's report row. Student counts are held back below
    /// `UsageReport.smallCourseThreshold`.
    var row: UsageCourseRow {
        let small = students.count < UsageReport.smallCourseThreshold
        return UsageCourseRow(
            courseCode: code, courseKey: key, courseName: name, term: term.shortLabel,
            termInferred: termInferred, archived: archived,
            enrolledStudents: small ? nil : students.count,
            activeStudents: small ? nil : activeStudents.count,
            smallCourse: small, instructors: instructors.count,
            teachingAssistants: teachingAssistants.count, assignments: assignments,
            studentSubmissions: studentSubmissions, labParticipations: labParticipations)
    }
}

extension UsageTotals {
    /// The totals over `courses`: people counted once however many courses
    /// they are in, everything else summed.
    init(folding courses: [UsageCourseFacts]) {
        var students = Set<UUID>()
        var active = Set<UUID>()
        var instructors = Set<UUID>()
        var tas = Set<UUID>()
        var perUser: [UUID: Int] = [:]
        var byStatus: [String: Int] = [:]
        var bySource: [String: Int] = [:]
        var byType: [String: Int] = [:]
        var byLanguage: [String: Int] = [:]
        for course in courses {
            students.formUnion(course.students)
            active.formUnion(course.activeStudents)
            instructors.formUnion(course.instructors)
            tas.formUnion(course.teachingAssistants)
            perUser.merge(course.studentSubmissionsByUser, uniquingKeysWith: +)
            byStatus.merge(course.studentByStatus, uniquingKeysWith: +)
            bySource.merge(course.studentBySource, uniquingKeysWith: +)
            byType.merge(course.assignmentsByType, uniquingKeysWith: +)
            byLanguage.merge(course.assignmentsByLanguage, uniquingKeysWith: +)
        }
        let activeCounts = active.compactMap { perUser[$0] }
        self.init(
            courses: courses.count,
            distinctCourseCodes: Set(courses.map { $0.code.lowercased() }).count,
            enrolledStudents: students.count,
            activeStudents: active.count,
            instructors: instructors.count,
            teachingAssistants: tas.count,
            assignments: courses.reduce(0) { $0 + $1.assignments },
            assignmentsByType: Self.sortedCounts(byType),
            assignmentsByLanguage: Self.sortedCounts(byLanguage),
            contentItems: courses.reduce(0) { $0 + $1.contentItems },
            submissions: UsageSubmissionTotals(
                student: courses.reduce(0) { $0 + $1.studentSubmissions },
                studentByStatus: Self.sortedCounts(byStatus),
                studentBySource: Self.sortedCounts(bySource),
                validation: courses.reduce(0) { $0 + $1.validationSubmissions },
                medianPerActiveStudent: Self.median(activeCounts)),
            labParticipations: courses.reduce(0) { $0 + $1.labParticipations },
            aiFeedbackReleased: courses.reduce(0) { $0 + $1.aiFeedbackReleased },
            tournamentsRun: courses.reduce(0) { $0 + $1.tournamentsRun })
    }

    /// Largest count first, then key order, so the output is stable.
    static func sortedCounts(_ counts: [String: Int]) -> [UsageCount] {
        counts.map { UsageCount(key: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
    }

    /// The median of `values`, or nil when there are none.
    static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Double(sorted[mid - 1] + sorted[mid]) / 2
        }
        return Double(sorted[mid])
    }
}

extension UsageIntegrations {
    init(folding courses: [UsageCourseFacts]) {
        self.init(
            brightSpaceCourses: courses.filter(\.usesBrightSpace).count,
            ltiCourses: courses.filter(\.usesLTI).count,
            aiFeedbackCourses: courses.filter(\.usesAIFeedback).count,
            githubSubmissionCourses: courses.filter(\.usedGitHubSubmissions).count)
    }
}
