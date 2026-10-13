// LoadTest/LoadScenario.swift
//
// The two request streams the load test drives. They are the server's hot
// paths: the routes with the most traffic during a deadline.

enum LoadScenario: String, CaseIterable, Sendable {
    /// A runner slot polls `POST /api/v1/worker/request` for a job.
    case runnerPoll = "POST /api/v1/worker/request"
    /// A result view polls `GET /api/v1/submissions/:id` while it waits.
    case statusPoll = "GET /api/v1/submissions/:id"
}
