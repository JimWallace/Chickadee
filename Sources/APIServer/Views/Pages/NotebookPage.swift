// APIServer/Views/Pages/NotebookPage.swift
//
// GET /testsetups/:id/notebook: the JupyterLite notebook editor. A shim: the
// layout plus `NotebookBody`, which owns every element. `?embedded=1` drops
// the site chrome, as the workbench pane once loaded it.

import Elementary

struct NotebookPage: HTML {
    let page: PageRequestContext
    let notebook: NotebookBody

    var body: some HTML {
        BaseLayout(title: "Notebook", page: page, embedded: notebook.embedded) {
            notebook
        }
    }
}
