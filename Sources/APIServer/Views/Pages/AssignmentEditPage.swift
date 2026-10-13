// APIServer/Views/Pages/AssignmentEditPage.swift
//
// GET /instructor/:assignmentID/edit: the standalone assignment editor. A
// body-partial shim: the layout around one `AssignmentEditBody`, which the
// workbench's left pane renders too.

import Elementary

struct AssignmentEditPage: HTML {
    let page: PageRequestContext
    let edit: EditAssignmentContext

    var body: some HTML {
        BaseLayout(
            title: edit.assignmentName, page: page, flash: FlashMessages(notice: edit.notice),
            embedded: edit.embedded == true
        ) {
            AssignmentEditBody(edit: edit, csrfToken: page.csrfToken, appVersion: page.appVersion)
        }
    }
}
