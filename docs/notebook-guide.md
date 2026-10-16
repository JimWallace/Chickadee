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
| 1. Pinned | The stored override of the item. NB7 writes it. |
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
