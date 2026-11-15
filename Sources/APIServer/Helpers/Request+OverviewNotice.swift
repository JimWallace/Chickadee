// APIServer/Helpers/Request+OverviewNotice.swift
//
// A one-shot notice for the instructor Overview, carried in the session so a
// redirect to `/instructor` keeps its plain location (UI audit #3007,
// finding 5). "Create & Validate" and "Save & Validate" used to land on the
// Overview with no word about what happened.

import Vapor

extension Request {
    private static let overviewNoticeKey = "overview_notice"

    /// The header that `Public/inplace-forms.js` sends on each workbench
    /// pane save.
    static let inPlaceSaveHeader = "X-Chickadee-Inplace"

    /// Sets the notice the next Overview render shows once.
    ///
    /// A save from the workbench pane sets none. The pane follows the
    /// redirect with `fetch`, reloads itself and never shows the Overview,
    /// so the notice would wait in the session and appear on a later,
    /// unrelated Overview visit.
    func setOverviewNotice(_ text: String) {
        guard headers.first(name: Self.inPlaceSaveHeader) == nil else { return }
        session.data[Self.overviewNoticeKey] = text
    }

    /// The pending notice, cleared as it is read; nil when there is none.
    ///
    /// Only a page navigation reads it. `multipart-forms.js` posts with
    /// `fetch`, which follows the redirect to `/instructor` in the background
    /// and then navigates there. Without this check the background GET took
    /// the notice, and the page that the instructor sees showed none. A
    /// request with no `Sec-Fetch-Dest` header (an older browser) still
    /// reads it.
    func takeOverviewNotice() -> String? {
        guard isPageNavigation else { return nil }
        guard hasSession, let text = session.data[Self.overviewNoticeKey] else { return nil }
        session.data[Self.overviewNoticeKey] = nil
        return text
    }

    /// False only when the browser says that the request is not for a page:
    /// `Sec-Fetch-Dest` is present and is not `document` (a `fetch` sends
    /// `empty`).
    private var isPageNavigation: Bool {
        guard let dest = headers.first(name: "Sec-Fetch-Dest") else { return true }
        return dest.lowercased() == "document"
    }
}
