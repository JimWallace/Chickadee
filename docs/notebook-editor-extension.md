# The Chickadee JupyterLite extension

This document describes `@chickadee/jupyterlite-extension`, the part of the
notebook editor that Chickadee owns (notebook views, NB2). The source is in
`Tools/jupyterlite/chickadee-extension/`. The notebook page talks to the
extension through the `jupyter-iframe-commands` bridge and through
`postMessage`.

## What it does

- It registers two themes, "Chickadee" and "Chickadee dark". Each theme loads
  JupyterLab's own light or dark theme, then sets `body[data-ck-theme]`. The
  variable blocks in `style/index.css` override only the variables that differ.
  Every variable name in the blocks exists in the vendored
  `@jupyterlab/theme-light-extension` (JupyterLab 4.6.4).
- It hides the chrome of Notebook 7, because the page draws the one toolbar
  (`NotebookToolbar`):
  - A settings override hides the top area
    (`@jupyter-notebook/application-extension:top`).
  - A settings override disables the items of the notebook toolbar.
  - Notebook 7 has no setting for the menu bar or for the toolbar strip, so the
    extension hides the two widgets through the shell and the panel.
  - Keyboard shortcuts continue to work.
- It registers the commands below and posts the events below.
- It writes nothing into a notebook: no cell source, no metadata and no output.
  It reads no layout.

## Commands (page to editor)

The page calls these commands through `window.chickadeeEditorCommand`, which
is the bridge-first command channel of `notebook.js`.

| Command | Arguments | Effect |
|---|---|---|
| `chickadee:set-theme` | `{theme: "light" \| "dark"}` | Selects "Chickadee" or "Chickadee dark". |
| `chickadee:configure` | `{patterns: [String]}` | Sets the definition patterns that `ck:active-cell` and `chickadee:reveal` use. |
| `chickadee:set-guide` | `{guide}` | Draws the student guide (`docs/notebook-guide.md`, "In the editor"): the task headers and the checks lines. |
| `chickadee:set-suite` | `{suite}` | Draws the instructor suite as margin cards (`docs/notebook-guide.md`, "The margin cards"). |
| `chickadee:select-item` | `{itemID}` (null clears) | Selects the test's card, opens it, and scrolls to the cell that the test links to. Returns false when the test links to no cell. |
| `chickadee:reveal` | `{cellId}`, `{index}`, `{name}`, `{section}` or `{tag}` | Selects the cell and scrolls to it. A `name` finds the last cell that defines the name. A `section` finds the first code cell after the `## ` heading. A `tag` finds the first cell with that tag. |

`notebook-toolbar.js` sends `chickadee:configure` and `chickadee:set-theme` on
the first `ck:kernel` event of each editor document. It sends
`chickadee:set-theme` again when the colour scheme of the page changes.

## Events (editor to page)

Each event is a `postMessage` to the parent window, for this origin only. The
`ck` field names the event.

| Event | Fields | Reader |
|---|---|---|
| `ck:kernel` | `status`: `starting`, `idle`, `busy` or `dead` | The kernel chip, and the loading panel (idle or busy closes it). |
| `ck:notebook-open` | none | The loading panel closes. The cells are drawn, and the kernel can still be starting: a cell run before the kernel is ready waits for it, and the kernel chip shows the kernel state. |
| `ck:active-cell` | `cellId`, `index`, `names`, `task` | The outline. `names` are the names that the cell defines. `task` is the `sectionID` of the task that holds the cell, or null. |
| `ck:tasks` | `tasks`: `[{sectionID, status}]`, `reflections`: `[{tag, status}]` | The outline. Sent after each redraw of the guide, in the guide's task order, with the status that the editor shows (`starter` included). A reflection is `written` or `empty`. |
| `ck:cell-ran` | `cellId`, `status`: `ok` or `error` | NB4 (the "ran without errors" signal). |
| `ck:saved` | `state`: `started`, `completed` or `failed` | The save state in the toolbar. |
| `ck:item-selected` | `itemID` (null when a card closes) | The workbench rail marks the row. |
| `ck:edit-test` | `itemID` | The workbench opens the suite sheet on the test's editor. |
| `ck:run-again` | `itemID` | The workbench saves the whole assignment and validates it again (the Save button). It does not run one test alone. |
| `ck:pin` | `itemID`, `anchor` | The workbench pins the test (`PUT /instructor/:id/suite-anchor`), then fetches the outline again. |
| `ck:pin-refused` | `itemID` | The workbench says that the clicked cell defines no name. |
| `ck:section-action` | `sectionID`, `action`: `rename`, `add-check` or `delete` | The workbench opens the section in the suite sheet and starts the action there. |
| `ck:add-check` | `sectionID`, `anchor` | The workbench opens the section's Add check. It does not use `anchor` yet. |

`ck:saved` is not in the brief. The page has no other save state to show,
because a student's work saves in the browser through the autosave of
JupyterLab.

## Definition patterns

The extension holds no language facts. The server sends the patterns from
`LanguageDescriptor.definitionLinePatterns`: the function patterns, then the
variable pattern (`variableScan`). They are on
`#jl-frame[data-definition-patterns]` as a JSON array. Each pattern matches one
line, and capture group 1 is the defined name. The syntax is the subset that
Swift and JavaScript share.

## The execution indicator must stay

`jl-kernel-diagnostics.js` reads the kernel state from the `data-status` of
`.jp-Notebook-ExecutionIndicator`. That indicator is an item of the notebook
toolbar. The settings override therefore keeps the `executionProgress` and
`kernelName` items. The toolbar strip is hidden, but the indicator stays in the
DOM. If the override removes the indicator, the boot diagnostics never see the
kernel reach idle, and the loading panel stays until the 75-second stall.
`notebook-toolbar-check.mjs` fails on this.

## Build and vendor

The labextension is built and committed, so `pip install` needs no Node.js:

1. In `Tools/jupyterlite/chickadee-extension/`, with JupyterLab 4.6.4 on the
   path, run `jlpm install`, `jlpm build` and `jlpm test`.
   `@jupyterlab/builder` is published only up to 4.5.11, so the build uses that
   version against the 4.6.4 core.
2. Run `scripts/vendor-chickadee-extension.sh`. It copies the labextension into
   `Public/jupyterlite/extensions/@chickadee/jupyterlite-extension/`, lists it
   in `federated_extensions` in `jupyter-lite.json`, and writes
   `Tools/jupyterlite/overrides.json` into `settingsOverrides`. These are the
   same changes that `jupyter lite build` makes.

`scripts/build-jupyterlite.sh` installs the extension from
`Tools/jupyterlite/requirements.txt` and copies `overrides.json`, so a full
rebuild (`revendor-kernels.yml`) gives the same result. CI runs
`scripts/vendor-chickadee-extension.sh --check` and
`scripts/verify-jupyterlite.sh`. Both fail if the bundle does not carry the
built extension and its overrides.

The `remoteEntry` and the chunks have content hashes, so they are cached for
one year. `style.js` and `jupyter-lite.json` have stable names, so they
revalidate on each load (`BundleAssetCacheMiddleware`). Do not patch the
vendored bytes in place.

## Findings (NB2)

- **Command ids.** `kernel:restart` does not exist in this build. The restart
  command of the notebook is `notebook:restart-kernel`. The other six ids in
  the brief exist.
- **The content factory.** `@jupyterlab/notebook-extension:factory` provides
  `NotebookPanel.IContentFactory`. An extension can replace the factory if
  `jupyter-lite.json` disables that plugin and the extension provides the
  token. This is untested. NB4 decides between the factory and `widgetAdded`.
- **The menu bar.** Notebook 7 has no setting for the menu bar. Only the zen
  command hides it, so the extension hides it through the shell.
