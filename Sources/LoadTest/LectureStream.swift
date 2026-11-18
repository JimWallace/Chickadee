// LoadTest/LectureStream.swift
//
// The request streams of one simulated lecture activity, in the order a
// student meets them, and the two end-to-end spans the plan's targets are
// written against.

enum LectureStream: String, CaseIterable, Sendable {
    /// Phase 1, join: the notebook page.
    case page = "GET /testsetups/:id/notebook"
    /// Phase 1, join: each kernel boot file the page lists.
    case kernelFile = "GET kernel boot file"
    /// Phase 4, watch: the live board's background refresh.
    case board = "GET /testsetups/:id/leaderboard?fragment=body"
    /// Phase 3, submit: the test setup zip the browser grades with.
    case setupDownload = "GET /api/v1/browser-runner/testsetups/:id/download"
    /// Phase 3, submit: the student's personalization seed.
    case seedDownload = "GET /api/v1/browser-runner/testsetups/:id/seed"
    /// Phase 3, submit: the manifest.
    case manifestDownload = "GET /api/v1/browser-runner/testsetups/:id/manifest"
    /// Phase 3, submit: the graded result.
    case resultPost = "POST /api/v1/submissions/browser-result"
    /// Phase 3, submit: the status poll until the result is stored.
    case statusPoll = "GET /api/v1/submissions/:id"
    /// One student's whole join: the page, then every kernel file.
    case joinSpan = "Join, page and kernel files (per student)"
    /// From the first submit download to a stored result (per student).
    case resultVisibleSpan = "Result visible after submit (per student)"

    /// A span is measured over several requests, so it has no HTTP status.
    var isSpan: Bool {
        self == .joinSpan || self == .resultVisibleSpan
    }
}
