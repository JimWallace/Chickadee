// Tests/APITests/Auth/UserFileNamespacePathTests.swift
//
// `FileMiddleware` percent-decodes the request path and lets the filesystem
// collapse `//` and `.` segments, so every spelling of a per-user notebook
// path must resolve to the same namespace in `UserFileNamespaceMiddleware`.
// A spelling that resolved to none skipped the check and served another
// user's notebook with no login.

import Testing

@testable import APIServer

@Suite struct UserFileNamespacePathTests {

    private static let owner = "0a1b2c3d-0000-4000-8000-000000000001"

    @Test(arguments: [
        "/jupyterlite/files/users/\(owner)/setup/assignment.ipynb",
        "/jupyterlite//files/users/\(owner)/setup/assignment.ipynb",
        "//jupyterlite/files//users/\(owner)/setup/assignment.ipynb",
        "/jupyterlite/files/./users/\(owner)/setup/assignment.ipynb",
        "/jupyterlite/./files/users/./\(owner)/setup/solution.ipynb",
        "/jupyterlite/files/%75sers/\(owner)/setup/assignment.ipynb",
        "/jupyterlite/%66iles/users/\(owner)/setup/assignment.ipynb",
        "/jupyterlite/files/users/%2e/\(owner)/setup/assignment.ipynb",
        "/JupyterLite/FILES/Users/\(owner.uppercased())/setup/assignment.ipynb",
        "/files/users/\(owner)/setup/assignment.ipynb",
        "/jupyterlite/lab/files/users/\(owner)/setup/assignment.ipynb",
        "/jupyterlite/notebooks/files/users/\(owner)/setup/assignment.ipynb",
    ])
    func everySpellingResolvesToTheOwner(path: String) {
        #expect(UserFileNamespaceMiddleware.requestedUserNamespace(from: path) == Self.owner)
    }

    @Test(arguments: [
        "/jupyterlite/files/shared/notebook.ipynb",
        "/jupyterlite/build/app.js",
        "/jupyterlite/files/users/",
        "/styles.css",
    ])
    func pathsOutsideTheNamespaceAreUnguarded(path: String) {
        #expect(UserFileNamespaceMiddleware.requestedUserNamespace(from: path) == nil)
    }
}
