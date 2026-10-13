// APIServer/Views/Pages/EditorResetPage.swift
//
// GET and POST /reset-editor: the confirmation step, and the page shown after
// the POST response has cleared the browser's site data.

import Elementary

struct EditorResetPage: HTML {
    let page: PageRequestContext
    /// True after the POST: the data is cleared.
    let done: Bool
    /// The same-origin path to return to (`safeEditorResetReturnPath`).
    let next: String

    var body: some HTML {
        BaseLayout(title: "Reset notebook editor", page: page) {
            PageStyle(
                """
                /* Narrow utility page; the global .main caps at 900px, trim further. */
                .reset-panel { max-width: 36rem; margin: 2rem auto; }
                .reset-panel h1 { margin: 0 0 .75rem; }
                .reset-lead { color: var(--gray-700); }
                .reset-actions { display: flex; flex-wrap: wrap; gap: .75rem; align-items: center; margin-top: 1.25rem; }
                .reset-note { color: var(--gray-600); font-size: var(--text-base); margin-top: 1rem; }
                """
            )
            div(.class("reset-panel")) {
                if done {
                    doneState
                } else {
                    confirmState
                }
            }
        }
    }

    @HTMLBuilder private var doneState: some HTML {
        div(.class("notice-box"), .role("status")) {
            h1 { "Editor reset" }
            p(.class("reset-lead")) {
                "The editor data cached in this browser is cleared; your submitted work is safe, and you are "
                    + "still logged in."
            }
        }
        div(.class("reset-actions")) {
            a(.class("btn btn-primary"), .href(next)) { "Reopen your assignment" }
            a(.class("btn"), .href("/")) { "Return to dashboard" }
        }
    }

    @HTMLBuilder private var confirmState: some HTML {
        h1 { "Reset the notebook editor" }
        p(.class("reset-lead")) {
            "Resetting clears the notebook editor’s cached data in "
            strong { "this browser" }
            ", so a kernel that never finishes loading can start again."
        }
        p(.class("reset-lead")) {
            "Your submitted work is safe and you stay logged in; only unsaved edits in this browser are lost."
        }
        form(.method(.post), .action("/reset-editor"), .class("reset-actions")) {
            CSRFField(token: page.csrfToken)
            input(.type(.hidden), .name("next"), .value(next))
            button(.type(.submit), .class("btn btn-primary")) { "Reset editor" }
            a(.class("btn"), .href(next)) { "Cancel" }
        }
        p(.class("reset-note")) {
            "If the editor still won’t load afterward, you can submit your "
            code { ".ipynb" }
            " file directly from the assignment page."
        }
    }
}
