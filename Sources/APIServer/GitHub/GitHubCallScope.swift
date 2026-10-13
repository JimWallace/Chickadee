// APIServer/GitHub/GitHubCallScope.swift
//
// What a GitHub call needs from its caller: the application (for the App
// client and the token cache), a database and a logger. Nothing else of a
// request is read, so a call made after the response was sent (the commit
// status post, #1925) passes a `BackgroundGitHubCallScope` and needs no
// request built on an event loop, which Vapor 5 does not have
// (docs/vapor-5-migration.md).

import Fluent
import Vapor

protocol GitHubCallScope: Sendable {
    var application: Application { get }
    var db: any Database { get }
    var logger: Logger { get }
}

extension Request: GitHubCallScope {}

/// The scope for GitHub work that outlives its request.
struct BackgroundGitHubCallScope: GitHubCallScope {
    let application: Application
    let logger: Logger

    var db: any Database { application.db }
}
