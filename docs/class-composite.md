# Class Composite

Design note for a class activity in which each student renders one part of a
shared image, and the class watches the full image form on the projector while
the submissions arrive. Nothing in this note is built yet. See **Status**.

The idea came from a sequence of computer-graphics and medical-imaging labs:
a framebuffer, the painter's algorithm, the z-buffer, ray casting, and CT
reconstruction. In each of these, the work divides naturally into independent
parts: tiles of a screen, projection angles of a scan, frames of an animation.
A class composite gives each student one part and shows the class the result
of all parts together.

## Status

| slice | what | state |
|---|---|---|
| 0 | This design note | proposed |
| 1 | Output contract: the `composite` footer field in `RunnerCore` | planned |
| 2 | The `classComposite` kind, the `composite` block, authoring and `set_activity` | planned |
| 3 | Slot dealing, and the slot as a per-student input | planned |
| 4 | Ingest: the `composite_contributions` table and the coverage row | planned |
| 5 | The composite view on the leaderboard page | planned |
| 6 | Reference fill, spare slots, and the `sum` and `gallery` compositors | planned |

Slice 5 is the first slice that a class can use. Slices 1 to 4 only supply data
to it. Run one session with TAs after slice 5, before slice 6.

## The name

**Class composite.** In computer graphics, *compositing* is the operation that
combines separate images into one. That is what this activity does, for every
compositor in the table below. The activity kind is `classComposite`, its
aggregation is `composite`, and the view is "the composite".

## The model

Three concepts cover every activity this note is for.

- **Contribution.** A small image, or a short sequence of frames, that the
  student's graded test produces.
- **Slot.** The part of the shared result that the student owns: a tile, a
  projection angle or a frame number. The server deals the slots.
- **Compositor.** The rule that combines the contributions into one image.

| Compositor | Combines contributions by | Example activity |
|---|---|---|
| `tile` | Drawing each one at its grid position | Each student shades one tile of a scene. The class is the GPU. |
| `sequence` | Playing them in slot order, as frames | Each student gates one phase of a heartbeat. The class makes a cine loop. |
| `sum` | Adding them pixel by pixel | Each student backprojects one angle. The class is the CT scanner. |
| `gallery` | Showing them side by side | Each student streams a scan over a slow link. The class watches a race. |

**Students write general code. The grader decides which part they compute.**
In a `tile` activity, a student writes `shade(x, y, t)`. In a `sum` activity, a
student writes `project(volume, angle)`. The test script calls that function
with the student's slot. So the starter notebook does not need to know the
slot, and a student cannot choose an easy part.

## Relation to the bug hunt

A class composite is not a new assignment type. It is a new activity kind, as
`bugHunt` and `roundRobin` are, and its aggregation is a sibling of `union`.
The bug hunt already has the structure that a composite needs: each student
covers items, and the class total is the union of the items.

| | Bug hunt (`union`) | Class composite (`composite`) |
|---|---|---|
| Item | A seeded bug variant | A slot |
| Who chooses the item | The student's tests find any variant | The server deals one slot to each student |
| What is stored for each item | Only that it is covered, and by whom | An image |
| Replacement | Never. The first finder wins. | The latest submission replaces the earlier one. |
| Class display | A count and a table | The composed image |
| Class goal | `itemsCovered` | `itemsCovered`, with no change |

So two concepts are new: **slot dealing**, and **a payload with a compositor**.
Everything else is existing activity machinery: the `activity` block, the
session `window`, materialization at ingest, the leaderboard page with its
polled refresh and its present mode, and the kind lock at the first student
submission.

## Design decisions (proposed)

1. **An activity kind, not a content type.** The same reason as every other
   activity (`class-activities.md`, decision 1): a composite needs grading, the
   window, achievements and freeze, and all of these hang off an assignment.
2. **The contribution travels in the JSON footer.** It is next to `score` and
   `metric`, so it uses the path that both grading substrates already use. An
   output file was rejected: it needs a new channel on every substrate.
3. **The contribution is raw pixels, not PNG.** `RunnerCore` is
   Embedded-Swift-compatible and must not decode images. The server checks
   only the length and the size cap. The browser draws raw pixels into an
   `ImageData` with no decoder.
4. **The slot is a per-student input.** The server already resolves
   per-student inputs once, with `gradingInputs`, for both substrates: the
   worker writes `Job.personalizedInputs` into the workspace, and the browser
   runner receives `personalizedInputs` from the seed endpoint and writes the
   same file. The slot is one more value in that set. This needs no new job
   field, no new environment variable and no new browser channel.
5. **Two tables with opposite rules.** Class progress is monotone: a slot that
   was correct once counts forever, so the progress number never goes down.
   That is the existing `class_item_coverage` rule, and the composite writes to
   that table. The images are not monotone: the latest replaces the earlier
   one, and a failed contribution stays visible. They go in a new table.
6. **A failed contribution is shown, with a mark.** A wrong tile in the image is
   the "dead pixel" that the class finds and discusses. This is part of the
   lesson. The instructor can hide failed contributions (see **Open
   decisions**).
7. **The composition runs in the browser.** The server never decodes or
   composes an image. Each compositor is a pure function in
   `Public/class-composite.js`, tested with `node --test`.
8. **The composite view is a leaderboard body.** The leaderboard page already
   selects its body by aggregation, polls with ETags, counts down the window,
   stops polling when the window closes, and has a staff present mode for the
   projector. The composite is one more body. It is not a new page. It is not
   free, though: the normal page selects its body with one flag for each
   aggregation, and present mode (`WebRoutes+LeaderboardPresent.swift`, its own
   `leaderboard-present` template) dispatches with an exhaustive `switch` on
   the aggregation. Slice 5 adds a `composite` case in both places.

## Data flow

### 1. The contribution (slice 1)

The test script writes the contribution in its footer:

```json
{"score": 1, "composite": {"w": 8, "h": 8, "frames": 30, "format": "rgb8", "data": "<base64>"}}
```

| Field | Meaning |
|---|---|
| `w`, `h` | Width and height of the contribution, in pixels |
| `frames` | Number of frames. `1` for a still image. |
| `format` | `gray8` or `rgb8` |
| `data` | Base64 of `w × h × frames × channels` bytes, frame by frame, row by row |

`interpretScriptOutput` passes the object through to an optional field on
`TestOutcome`. It does not decode `data`. `Tests/Fixtures/output-contract.json`
gains rows for a footer with a composite and for a footer without one, and CI
asserts them against the native build and the vendored wasm.

The contribution is attached to the test outcome, so a script can grade the
correctness of the contribution in the same run. The exit code and `score` are
the grade. The composite is a display. It never changes a grade.

### 2. The slot (slice 3)

**Dealing.** When a student first opens the assignment during the window, the
server deals the next free slot and stores it in `composite_slots`
(assignment, student, slot, dealt-at). The slot does not change after that. If
a submission arrives for a student with no slot (for example, the student opened
the page before the window), `gradingInputs` deals one at that time.

Dealing writes on a page load, so it must be idempotent and safe under a race.
A unique key on (assignment, student) makes a second deal for the same student
fail, and the loser reads the row that won. A unique key on (assignment, slot,
round) stops two students from receiving the same slot in one round; the loser
retries with the next free slot.

A student who does not come to class gets no slot, so absent students do not
leave fixed holes in the image.

**Dealing order.** One of `rowMajor`, `centreOut` or `random`. With
`centreOut`, the image grows from the middle, which reads well on a projector.

**More students than slots.** Deal a second round. Two students then own the
same slot, and the composite shows the latest passing contribution.

**Delivery.** The slot is the input `slot` in the per-student input set, so a
Python test reads it from `_ck_inputs.py`, and each other language reads it
from its own inputs file. For a `tile` layout, the inputs also carry `col` and
`row`, so a test script does not repeat the grid arithmetic.

**Staff.** A staff member's validation submission gets the reference slot
(slot 0) unless the staff member asks for another.

### 3. Ingest (slice 4)

At both ingest paths (the worker results and the browser result routes), for an
assignment with a `classComposite` activity:

1. Validate the payload: the format is known, the length matches the
   dimensions, and the size is not more than the cap (64 KB for each
   contribution). An invalid payload is discarded with a log line. The grade
   is not changed.
2. Upsert one row in `composite_contributions`: assignment, slot, student,
   submission, payload, passed, time. The latest submission for a student
   replaces that student's earlier row.
3. If the contribution passed, insert `slot-<n>` into `class_item_coverage`.
   The unique constraint keeps only the first, so this is idempotent.

`deleteCourse` must delete the rows in both new tables, as it deletes
`class_coverage_runs`.

### 4. The composite view (slice 5)

The leaderboard page shows the composite body when the aggregation is
`composite`. The image data comes from a JSON endpoint, so the polled HTML
region stays small:

```
GET /testsetups/:testSetupID/composite?since=<cursor>
```

It returns the contributions that changed after the cursor, and a new cursor.
It uses an ETag. Staff receive every contribution. A student receives only
their own (see **Student view** below).

**Slot states.** Each slot has one of four states, so the class can see the
image while it is rendered:

| State | Display |
|---|---|
| Empty: no student has the slot | Blank, with a thin grid outline |
| Rendering: a submission for the slot is queued or grading | A pulse in the slot |
| Failed: the latest contribution did not pass | The output, with a red outline |
| Passed | The output, animated if it has frames |

The rendering state comes from the submission status that the server already
stores. No new grading signal is necessary.

**Live arrival.** A new contribution fades into its slot, so the room sees each
change.

**Playback.** Play, pause and a frame slider. All slots use one clock, so the
full image moves together at the `frameRate` of the block.

**Present mode.** The existing staff present mode shows the image only, full
screen, with the progress line under it: "31 of 48 tiles complete".

**Staff view.** The leaderboard page is staff-only for this kind. Point at a
slot to see the owner's handle and the test result.

**Student view: their own contribution only.** The full composite is for the
projector. A student does not see the composite on their own device. Instead,
the student's result page shows their own contribution, drawn by the same
`class-composite.js` code at a larger scale, with its slot ("Your tile: column
3, row 5") and its state. A student sees what they added to the image on the
screen, and checks it before they look up.

A composite activity therefore ignores `leaderboardVisibleToStudents`: the
leaderboard page is staff-only for this kind, and the save-time checks refuse
the switch for it, so the meaning of the switch is not ambiguous. The JSON
endpoint is staff-only for the full set. A student request returns only that
student's own contribution.

**UI rules.** The page JS goes in `Public/class-composite.js`, with no inline
script (#1516). JS draws pixels into the `<canvas>`, but it toggles classes for
the slot states and makes no other styling decision. The body uses the
component vocabulary in `docs/ui-design.md`. The change needs a
visual-regression baseline and a `ui-review` pass.

## The manifest

```json
"activity": {
  "kind": "classComposite",
  "window": { "opensAt": "2026-11-04T14:30:00Z", "closesAt": "2026-11-04T15:20:00Z" },
  "composite": {
    "compositor": "tile",
    "layout": { "cols": 8, "rows": 6 },
    "contribution": { "w": 8, "h": 8, "frames": 30, "format": "rgb8" },
    "dealOrder": "centreOut",
    "frameRate": 12,
    "showFailed": true
  }
}
```

| Field | Meaning |
|---|---|
| `compositor` | `tile`, `sequence`, `sum` or `gallery` |
| `layout` | `{cols, rows}` for `tile` and `gallery`; `{count}` for `sequence` and `sum` |
| `contribution` | The dimensions and format that every contribution must have. Ingest refuses a contribution that does not match. |
| `dealOrder` | `rowMajor`, `centreOut` or `random` |
| `frameRate` | Frames per second for playback |
| `showFailed` | Show failed contributions with a mark (`true`), or show the slot as empty (`false`) |

`ActivityAuthoring` refuses a block at save when a field is missing or out of
range, or when the total payload for all slots is more than 4 MB.

## Compatibility rules

| Seam | Rule |
|---|---|
| Suite rebuilds | `makeWorkerManifestJSON(preserving:)` already keeps the `activity` block. `AssignmentHelpersManifestTests` gains a composite round trip. |
| Surgical edits | A `withComposite` rebuild, like `withWindow`, so no edit drops another field. |
| Old runners | An old `RunnerCore` drops the unknown footer field, so the contribution is lost with no error. A new capability token, `activity-composite`, keeps a composite job away from a runner that does not advertise it. The browser wasm ships with the server, so it is always current. |
| Browser grading | Permitted. A composite stages no opponent. |
| Output contract | `output-contract.json` only gains rows. |
| Setup cache | The key hashes the manifest. Assignments without a composite keep their key. |
| Versioning and bundles | The block travels in the manifest, as the other activity fields do. |
| MCP | `set_activity` accepts the kind and the block. Every kind list derives from `ActivityKind.allCases`, so `MCPActivityCoverageTests` covers the new kind. |
| Class goal | `itemsCovered`, which the sweep already evaluates. No new goal shape. |

## Slices

Each slice is one PR. Each slice leaves `main` green, adds tests for what it
adds, and keeps every existing assignment on the code path it uses now.

1. **Output contract.** The `composite` footer field, the optional
   `TestOutcome` field, and the new contract rows. Nothing reads the field yet.
2. **Kind and authoring.** `ActivityKind.classComposite`, the `composite`
   aggregation, the `composite` block, the save-time checks, the edit-page
   control and `set_activity`.
3. **Slots.** `composite_slots`, dealing in the three orders, the slot in
   `gradingInputs`, and the `activity-composite` capability token.
4. **Ingest.** `composite_contributions`, the payload checks, the coverage row,
   and `deleteCourse`.
5. **The composite view.** The JSON endpoint, `class-composite.js` with the
   `tile` and `sequence` compositors, the four slot states, playback, present
   mode, the student's own-contribution panel on the result page, the node
   tests, the visual-regression baseline and `ui-review`.
6. **Reference fill, spare slots, `sum` and `gallery`.** Reference fill is a
   staff action that renders the reference solution for each empty slot and
   shows those slots dimmed. It is a server-initiated job that waits behind
   every student submission, with the claim-order rule of the corpus run. A
   spare slot is a second slot that a student who finished can ask for.

## Risks

- **Polling load.** Only the projector polls the full composite, and it is one
  client. A student page polls only for its own contribution, at a slower
  rate. The ETag and the `since` cursor make an unchanged poll cheap.
- **Payload size.** 48 slots with 30 RGB frames of 8 × 8 pixels is about
  280 KB of pixels in total, or about 370 KB as base64. The cap for each
  contribution and the 4 MB limit at save keep this small.
- **Test time.** A test renders only the student's slot, not the full image,
  so it stays well below the 10-second limit.
- **Attendance.** Dealing at arrival handles absent students. Reference fill
  (slice 6) handles a small class. Until slice 6, a small class sees holes.

## Open decisions

Decided: **the composite is for the projector, and each student sees only their
own contribution** (see **Student view**).

Open:

1. **Failed contributions.** Show them with a mark by default
   (`showFailed: true`), or hide them by default?
2. **Empty slots.** Reference fill, spare slots, or both?

## Activities this enables

| Activity | Compositor | Available after |
|---|---|---|
| The class is the GPU: each student shades one tile of an animated scene | `tile` | slice 5 |
| Cine loop: each student gates one cardiac phase | `sequence` | slice 5 |
| Class film: each student renders one segment of a fly-through | `sequence` | slice 5 |
| The class is the CT scanner: each student backprojects one angle | `sum` | slice 6 |
| Teleradiology race: each student streams one scan over a slow link | `gallery` | slice 6 |
