import Fluent
import Foundation

/// Whether `caller` may read a path in the user-file namespace,
/// `users/<owner>/<setupID>/…` (#2895).
///
/// - The owner reads their own folder.
/// - An admin reads every folder.
/// - Anyone else reads another user's file only inside a setup, and only as
///   course staff (`.ta`+) in that setup's course while the course is live.
///   A listing above the setup level (`users/`, `users/<owner>/`) names every
///   user, so it is the owner's or an admin's only.
///
/// Before #2895, staff in ANY live course read every user's folder
/// deployment-wide, which let a TA in one course read another course's
/// solution notebooks and students' work. One policy for both doors: the
/// static `UserFileNamespaceMiddleware` and `JupyterLiteContentsRoutes`.
func mayReadUserFile(
    _ caller: APIUser, owner: String?, setupID: String?, db: any Database
) async throws -> Bool {
    if caller.isAdmin { return true }
    guard let callerID = caller.id?.uuidString.lowercased() else { return false }
    guard let owner else { return false }
    if owner.lowercased() == callerID { return true }
    guard let setupID, !setupID.isEmpty,
        let setup = try await APITestSetup.find(setupID, on: db),
        let course = try await APICourse.find(setup.courseID, on: db),
        !course.isArchived
    else { return false }
    return try await isCourseStaff(caller, inCourse: setup.courseID, db: db)
}
