// APIServer/Services/ContentItemVisibility.swift
//
// Whether a student sees one content item. A standalone item follows its own
// published flag. An item attached to an assignment (a lab's slides) also
// waits for the assignment: a student sees it whenever they can work on the
// assignment (open to them, an extension included), and after it has run (a
// deadline close). The student course page and the hosted
// file route both ask this, so a guessed `/content-files/…` URL cannot reach
// material the page does not show yet.

import Foundation

enum ContentItemVisibility {
    /// True when a student may see `item`. `assignment` is the item's attached
    /// assignment, looked up by the caller; it is ignored for a standalone
    /// item. An attached item whose assignment is gone (nil) is hidden.
    ///
    /// `studentCanSubmit` is the per-student answer the caller already has
    /// (`isAssignmentEffectivelyOpen`, or the dashboard row's `isOpen`): a
    /// student who can complete the assignment, by an extension too, sees its
    /// material. Otherwise the assignment rule is
    /// `assignmentVisibleToStudentByState` (open, or closed after its due
    /// date), with a future open date holding it back even while `.open`. A
    /// staff-only preview, a draft closed before its deadline and a
    /// not-yet-started assignment all keep the item hidden.
    static func isVisibleToStudents(
        _ item: APICourseContentItem, attachedTo assignment: APIAssignment?, studentCanSubmit: Bool = false,
        now: Date = Date()
    ) -> Bool {
        guard item.isPublished else { return false }
        guard item.assignmentID != nil else { return true }
        guard let assignment, assignment.id == item.assignmentID else { return false }
        if studentCanSubmit { return true }
        if let startsAt = assignment.startsAt, now < startsAt { return false }
        return assignmentVisibleToStudentByState(assignment, now: now)
    }
}
