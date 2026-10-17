# The notebook guide: tests anchored to cells

This document describes how Chickadee links each test to the notebook cell that
it checks, and the student guide that the notebook editor reads. It is part of
the notebook views work (NB3). The editor headers and checks lines (NB4, "In
the editor" below) and the instructor margin cards (NB7) use these two parts.

## Anchors

`NotebookTestAnchoring` (`Sources/Core/NotebookTestAnchoring.swift`) gives each
suite item an **anchor**. An anchor is a name that a code cell defines, or a
`## ` section. It is not a cell position. Thus one anchor finds its cell in the
starter, in the solution and in the working copy of a student, even when the
cells move.

The resolver uses the first rule that applies:

| Rule | Anchor |
|---|---|
| 1. Pinned | The stored override of the item: `TestSuiteEntry.anchor`, which the pin writes ("The margin cards" below). |
| 2. Notebook check | The `variable` field of the check (`function_exists`, `variable_exists`, the three `data_frame_*` kinds, `series_equality`, `numeric_array_close`). |
| 3. Pattern family | `functionName`. For `variable_equality`, the variable that the case of the script reads. |
| 4. Script test | The identifiers in the script that the solution defines. One match is that name. If there are more matches, the first one in the notebook is used, and the anchor is `ambiguous`. If there is no match, the next rule applies. |
| 5. Section | The suite section of the item, by its `## ` heading: the first code cell after the heading. |
| 6. None | `unlinked`: the item shows as "Not linked to a cell". |

`figure_count`, `cell_contains`, `ast_structure` and `program_io` read no name.
They use rule 5.

Grading never reads an anchor.

### Defined names

`scanNotebookDefinitions` (`Sources/Core/NotebookDefinitionScan.swift`) gives
the names that a notebook defines, each with the index of its cell:

- **Functions** come from `scanNotebookForSectionsAndFunctions`. Each entry of
  that scan now has its `cellIndex`.
- **Variables** come from one top-level assignment pattern for each language,
  `LanguageDescriptor.variableScan`. The pattern does not match a comparison
  (`==`) or an indented line. A name that starts with `_` is private and is not
  an anchor.
- A name that is defined two times resolves to the **last** definition, as in
  the function scan.
- A language that has no notebook (C++, Racket, Java), or no declared language,
  gives `unsupportedReason`. It does not give an empty result. The scan still
  reads the sections.

## The student guide

`GET /testsetups/:id/notebook-guide.json` returns `NotebookGuide`
(`Sources/APIServer/Models/NotebookGuide.swift`). `NotebookGuideBuilder` builds
it. The route reads the inputs and caches the result for each student and
submission (`NotebookGuideCache`, 120 seconds).

| Field | Contents |
|---|---|
| `attempt` | The latest submission: its number, `percent`, `points`, `pointsPossible` and `url`. It is `{"pending": true}` while the submission is in grading, and `null` before the first submission. |
| `tasks` | One task for each suite section, in order. Checks that are in no section, or in a section that no longer exists, make a last task, "Other checks". |
| `tasks[].label`, `name` | "Task 2" and "Average heart rate", from the heading "Task 2: Average heart rate". If there is no colon, the label is `null`. |
| `tasks[].points` | All tests of the task, including the hidden tests. |
| `tasks[].anchors` | The anchors of the public tests of the task: `function` or `variable` for a name that the solution defines, `name` for a name that it does not define, or `section`. A task with no public test has the anchor of its heading. |
| `tasks[].status` | `fresh` before the first attempt. After it, `pass` or `fail` from the public checks. It is `null` during grading, when the task has no public check, or when a public check has no result. The editor changes it to `starter` when the cell is the same as the starter. |
| `tasks[].checks` | Public checks only. Each check has its `name`, a `kind` (`check`, `family` or `script`) and a `result`. A failure also has a `detail` and a `hint`. |
| `tasks[].hiddenCount` | The release and secret tests of the task. |
| `starterSources` | The source of each anchor in the personalized starter of this student. The key is the anchor name, or `section:<heading>`. Trailing whitespace and CRLF are removed. |
| `reflections` | The cells with the tag `reflection`, which AI-assisted feedback reads. |

These rules keep the guide safe:

- The guide shows public results only. A release or secret test is a count in
  `hiddenCount`. It has no name, no result, no text and no anchor.
- A student cannot read the guide of a closed assignment that they never
  opened. This is the same gate as the notebook source.
- `detail` is the short result after the "Failure detail shown to students"
  setting of the check. It is the text that the results page shows. The guide
  never sends the long output.
- `hint` is the hint of the check. The guide sends it only for a failure.
- The guide reads the solution on the server to resolve rule 4. No part of the
  solution goes into the response.
- With no solution notebook yet, the starter of the student gives the anchors.
  The starter has the same headings and, usually, the same function stubs.

## In the editor

The notebook page (NB4, design frame 18a) shows the guide in two places.

**The outline** (`Public/notebook-guide.js`) is beside the editor. It shows the
attempt card and one row for each task: a glyph, the name and the points. A row
click reveals the task in the editor (`chickadee:reveal`). The row of the task
under the cursor has `aria-current`. Below 1100px the outline is a row of chips
under the toolbar. Below 640px it is hidden. Only a student who can submit sees
it, and not in the embedded workbench.

**The editor** (`chickadee-extension/src/guide.ts` and `guideView.ts`) draws
two rows for each task:

- A **task header** above the `## ` heading of the task, in the header widget
  of that cell. It has the status glyph, the label, the points and a pill. With
  no heading, the header goes above the first anchored cell.
- A **checks line** under the last anchored code cell, in the footer widget of
  that cell. It has "Checked in attempt N" (or "Checked when you submit"), a
  chip for each public check, and the count of hidden tests. Each failure shows
  its detail and the hint of the instructor, two at most.

The pill gives the status:

| Status | Pill |
|---|---|
| `pass` | "Passed in attempt N" |
| `fail` | "K checks failed in attempt N" |
| `starter` | "Still the starter code". Every anchor cell is the same as `starterSources`. |
| `fresh` | "Not submitted yet" |
| `null` | "Attempt N is being graded" while grading, else no pill |

"· edited since" follows a pass or a fail when an anchor cell changed after the
attempt. The editor keeps the sources of the attempt in `localStorage`, from the
first time that the browser sees the attempt. An edit made before that first view, or in
another browser, does not show as "edited since".

A cell whose anchored name is gone (a renamed function) shows "Can't find
`name` in your notebook" in its checks line.

Rules that keep the editor fast and safe:

- JupyterLab gives an empty cell header and footer zero height. The view adds
  `ck-guide-host` to a header or footer that it draws into, and the stylesheet
  gives that node its own height.
- The view reads no layout. It redraws at most once for each animation frame,
  and 500ms after the last edit. A redraw whose cells did not change touches no
  node, so a run, which changes only outputs, redraws nothing.
- The view never changes a cell, its metadata or its outputs. Every string from
  the guide goes in through `textContent`.
- Without the extension, the outline still shows the statuses of the server.

`Tools/editor-smoke-test/notebook-guide-check.mjs` checks all of this in a real
browser. CI runs it in `browser-probes.yml`.

## The instructor's suite outline

`GET /instructor/:assignmentID/suite-outline.json` returns
`InstructorSuiteOutline` (`Sources/APIServer/Models/InstructorSuiteOutline.swift`).
`InstructorSuiteOutlineBuilder` builds it. It is for course staff only, because
it names hidden tests and the solution's results. The workbench rail (NB6)
draws it, and the margin cards (NB7) read it.

| Field | Contents |
|---|---|
| `validation` | The assignment's `validationStatus`, the time of the last solution run, and the `issues`: one `failsOnSolution` for each item that does not pass on the solution. |
| `totals` | The number of suite items and their points. |
| `sections` | One section for each suite section, in order, then the items in no section (`id` null). Each has its `title`, `label` and `points`, and the items that link to a cell. |
| `sections[].items` | Each item: its `id` (the script filename), `name`, `kind` (`check`, `family` or `script`), `checkKind`, `tier`, `points`, `anchor` and `solution` result. |
| `unlinked` | The items that link to no cell, from any section. |

The anchors use the rules in "Anchors" above. They read the solution, or the
starter when there is no solution yet. `anchor.source` is `pinned` for a
pinned item (rule 1), else `auto`. The `solution` result comes from the last validation run, and is null
before one. NB8 adds the starter run.

## The margin cards

In the workbench (NB7, design frame 18c), the extension draws the suite beside
the notebook. `Public/workbench-rail.js` sends the outline with
`chickadee:set-suite`, and sends it again when the editor reloads.

- **A section card** sits beside the section's `## ` heading. It shows the
  label, the points and the number of checks, and a ⋯ menu: Rename, Add check
  and Delete. Each one opens the section in the suite sheet and starts that
  action there. Delete asks before it acts.
- **A test card** sits beside the cell that the test links to. A card that
  fails on the solution is red, and its cell has a red outline. Under the
  cards are "Linked by" with the names, and "+ Add check for this cell".
- **A selected card** opens. It shows the result detail, the script source for
  a hand-written test, and Edit test, Run again and Pin to a cell. A click on
  a rail row selects the card (`chickadee:select-item`), and a click on a card
  marks the rail row.
- **Below 1100px** of editor width, the cards fold into one strip for each
  cell: "3 checks · 3 pts", then "1 fails on the solution" when one does.

### Pin to a cell

Pin to a cell starts a pick mode. The next click on a code cell pins the test
to the first name that the cell defines. Escape or a click on a cell that
defines no name stops it. `PUT /instructor/:id/suite-anchor` with
`{script, anchor}` writes `TestSuiteEntry.anchor`; `anchor: null` clears it.
The route is for TAs and above.

- Only a **hand-written** test can be pinned. The route refuses a test that a
  pattern family or a notebook check generates, because the generator writes
  its anchor (rules 2 and 3), and a regeneration would lose the pin.
- A suite save keeps each script's pin (`makeWorkerManifestJSON(preserving:…)`
  in `Sources/APIServer/Helpers/ManifestFileHelpers.swift`).
- The runner never receives the pin: the `RunnerManifest` init
  (`Sources/Core/RunnerManifest.swift`) removes it. Grading does not read it.

`Tools/editor-smoke-test/workbench-margin-check.mjs` checks the cards, the
selection, the fold and the pin in a real browser.

## When an attempt is graded

When grading finishes while the student is still in the editor (NB5, design
frame 18f), the page fetches the guide again and sends it to the extension. The
headers, the checks lines and the outline update in place. The page does not
reload, and the kernel does not restart. Then a toast under Submit says the
grade (`NotebookGradedToast`, `Public/notebook-graded.js`).

- **Browser-graded.** `notebook.js` calls `ChickadeeGraded.graded()` when the
  browser runner has posted the results.
- **Worker-graded.** `notebook.js` no longer opens the results page. It calls
  `ChickadeeGraded.watch(submissionID)`, which polls
  `/api/v1/submissions/:id` as `app.js` does: after 1 second, then each wait
  half as long again, up to 10 seconds, for at most 5 minutes.
- **A page opened while its attempt grades** watches that attempt with no
  toast, so the statuses become current.

The toast has the bird, "Attempt 3 graded", the grade, "All 10 checks passed."
or "7 of 10 checks passed." (the public checks), See results and Keep editing.
It never closes by itself. At 100% three stars show and the bird hops once,
unless the student reduces motion. Below 100% the bird stays calm. The toast
does not write `ck-celebrated:<submissionID>`, so the results page still plays
the full celebration (`docs/result-celebration.md`).

Without the extension, the page keeps its old flow: the inline results panel
(`#nb-results`) for a browser-graded attempt, and the results page for a
worker-graded one. With the extension, that panel stays hidden.

`Tools/editor-smoke-test/notebook-graded-check.mjs` checks the browser-graded
path in a real browser. The harness starts no native runner, so
`Tests/BrowserRunnerJSTests/notebook-graded.test.mjs` checks the poll.

## What NB3 found

- **Cell ids.** Stored notebooks do not always have nbformat 4.5 cell `id`s. No
  code adds them, and no code removes them. The new-assignment scaffold
  declares `nbformat_minor` 5 but writes cells with no id. Anchoring does not
  need ids, because it links by name. `ReflectionCells` and
  `PersonalizedCellRestoration` use an id when it is there, and the cell
  position when it is not.
- **Points.** `TestSuiteEntry.points` holds the points of each test. A check or
  a family case writes its points into the entry that it generates. No section
  total is stored, so a task total is the sum of the entries of the section.
- **Staff seeds.** A staff member sees the notebook with their own seed
  (`AssignmentSeedStore`, one seed for each user and assignment). The notebook
  page has no "view as a student" mode. MCP `preview_personalization` with a
  `seedHex` is the nearest feature. NB6 adds the preview.
