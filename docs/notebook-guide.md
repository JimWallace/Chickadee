# The notebook guide: tests anchored to cells

This document describes how Chickadee links each test to the notebook cell that
it checks, and the student guide that the notebook editor reads. It is part of
the notebook views work (NB3). The editor headers and checks lines (NB4) and the
instructor margin cards (NB7) use these two parts.

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
