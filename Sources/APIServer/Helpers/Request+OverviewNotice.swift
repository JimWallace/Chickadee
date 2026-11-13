// APIServer/Helpers/Request+OverviewNotice.swift
//
// A one-shot notice for the instructor Overview, carried in the session so a
// redirect to `/instructor` keeps its plain location (UI audit #3007,
// finding 5). "Create & Validate" and "Save & Validate" used to land on the
// Overview with no word about what happened.

import Vapor

extension Request {
    private static let overviewNoticeKey = "overview_notice"

    /// Sets the notice the next Overview render shows once.
    func setOverviewNotice(_ text: String) {
        session.data[Self.overviewNoticeKey] = text
    }

    /// The pending notice, cleared as it is read; nil when there is none.
    func takeOverviewNotice() -> String? {
        guard hasSession, let text = session.data[Self.overviewNoticeKey] else { return nil }
        session.data[Self.overviewNoticeKey] = nil
        return text
    }
}
