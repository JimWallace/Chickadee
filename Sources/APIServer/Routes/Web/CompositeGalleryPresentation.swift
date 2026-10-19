// APIServer/Routes/Web/CompositeGalleryPresentation.swift
//
// Every lab's image of a class composite that runs once per lab group
// (docs/lab-groups.md, slice 4c), for the staff leaderboard page. A lab joins
// the gallery when its session has ended, so the gallery shows finished
// images side by side. Each stage reads its lab's snapshot when the page
// opens and stops polling, because its session has ended.

import Core
import Fluent
import Foundation

struct CompositeGalleryPresentation {

    /// One lab's image.
    struct Lab {
        let name: String
        /// "31 of 48 tiles complete".
        let progressText: String
        let stage: CompositeStagePresentation
    }

    /// The labs whose session has ended, in the group set's order.
    let labs: [Lab]

    /// The gallery of a per-group composite, or nil for any other activity
    /// and when no lab's session has ended.
    static func build(
        setup: APITestSetup, activity: ClassActivity, assignment: APIAssignment?, now: Date = Date(),
        on db: any Database
    ) async throws -> CompositeGalleryPresentation? {
        guard activity.kind == .classComposite, activity.isPerGroup, let spec = activity.composite,
            let assignmentID = assignment?.id, let testSetupID = setup.id,
            let setID = try await CourseGroupStore.sets(courseID: setup.courseID, on: db).first?.id
        else { return nil }
        var labs: [Lab] = []
        for group in try await CourseGroupStore.groups(inSet: setID, on: db) {
            guard let groupID = group.id,
                let closedAt = try await ActivitySessionStore.session(
                    assignmentID: assignmentID, groupID: groupID, on: db)?.closedAt,
                closedAt <= now
            else { continue }
            let snapshot = try await CompositeSnapshot.build(
                .init(
                    assignmentID: assignmentID, testSetupID: testSetupID, courseID: setup.courseID, spec: spec,
                    groupID: groupID),
                since: .max, onlyUserID: nil, includeOwners: false, on: db)
            labs.append(
                Lab(
                    name: group.name,
                    progressText: "\(snapshot.complete) of \(snapshot.total) \(spec.compositor.slotNoun) complete",
                    stage: .board(
                        spec: spec, testSetupID: testSetupID, present: false, groupID: groupID,
                        pollUntilISO: closedAt.formatted(.iso8601))))
        }
        return labs.isEmpty ? nil : CompositeGalleryPresentation(labs: labs)
    }
}
