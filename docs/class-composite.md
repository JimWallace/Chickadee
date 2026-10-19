# Class Composite

Design note for a class activity in which each student renders one part of a
shared image, and the class watches the full image form on the projector while
the submissions arrive. Slices 1 to 6 are built. See **Status**.

The idea came from a sequence of computer-graphics and medical-imaging labs:
a framebuffer, the painter's algorithm, the z-buffer, ray casting, and CT
reconstruction. In each of these, the work divides naturally into independent
parts: tiles of a screen, projection angles of a scan, frames of an animation.
A class composite gives each student one part and shows the class the result
of all parts together.

## Status

| slice | what | state |
|---|---|---|
| 0 | This design note | shipped |
| 1 | Output contract: the `composite` footer field in `RunnerCore` | shipped |
| 2 | The `classComposite` kind, the `composite` block, the layout lock, authoring with the roster ratio, and `set_activity` | shipped |
| 3 | Slot dealing, and the slot as a per-student input | shipped |
| 4 | Ingest: the `composite_contributions` table and the coverage row | shipped |
| 5 | The composite view on the leaderboard page, with all four compositors | shipped |
| 6a | Reference renders and `emptySlots: reference` | shipped |
| 6b | Spare slots | shipped |
| groups | One image per lab group (`docs/lab-groups.md`, slices 4a to 4c) | shipped |

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
`roundRobin` is, and its aggregation is a sibling of `union`. The bug hunt is
not an `ActivityKind`: it is a contribution assignment
(`docs/collaborative-class-assignments.md`), and its coverage table
(`class_item_coverage`) already has the structure that a composite needs: each
student covers items, and the class total is the union of the items.

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

## Design decisions

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
   lesson. This is the default. The instructor can hide failed contributions
   with `showFailed: false`.
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

`interpretScriptOutput` reads the object into `CompositeContribution`
(`Sources/RunnerCore/CompositeContribution.swift`), an optional field on
`TestOutcome`. It checks the shape without decoding `data`: `w`, `h` and
`frames` are positive whole numbers, `format` is known, and `data` is standard
padded base64 whose decoded length is exactly `w × h × frames × channels` and at
most 64 KB. It computes that length from the text, so no pixel is decoded. Any
other shape gives no contribution, and the grade does not change. The browser
bridge carries the same object as `JSCompositeContribution`, with the footer's
keys, which are also the keys of the `Codable` form that the server decodes.

`Tests/Fixtures/output-contract.json` has rows for a valid contribution, a
failed test with a contribution, and four invalid shapes. CI asserts them
against the native build and the vendored wasm, which slice 1 re-vendored. The
server still validates every payload at ingest (slice 4), because a
browser-posted outcome is not trusted.

**The stored result keeps the contribution (slice 4).** Truncation in
`TestOutcomeCollection` cuts only `longResult` and copies `composite` unchanged.
A contribution is at most about 87 KB of base64, well inside the 6 MB result
budget, so the result keeps it. The composite view reads the
`composite_contributions` table, not the result.

The contribution is attached to the test outcome, so a script can grade the
correctness of the contribution in the same run. The exit code and `score` are
the grade. The composite is a display. It never changes a grade.

### 2. The slot (slice 3)

**Dealing.** When a student first opens the notebook page or the upload page
while the assignment is open and inside its window, the server deals a slot and
stores it in `composite_slots` (assignment, student, slot, round, dealt-at).
The slot does not change after that. If a submission arrives for a student with
no slot (for example, the student opened the page before the window), grading
deals one at that time. `CompositeSlots` (`Sources/APIServer/Services/`) owns
both paths. A deal never fails the page or the grading run: an error is logged,
and the run grades without the slot inputs.

The dealer takes the first (round, slot) that nobody holds, in deal order. So a
slot freed by a deleted student is dealt again, and a second round starts only
when every slot of the first is taken.

Dealing writes on a page load, so it is idempotent and safe under a race. A
unique key on (assignment, student) makes a second deal for the same student
fail, and the loser reads the row that won. A unique key on (assignment, round,
slot) stops two students from receiving the same slot in one round; the loser
retries with the next free pair. No insert runs inside a transaction, because a
failed insert on Postgres aborts the transaction.

A student who does not come to class gets no slot, so absent students do not
leave fixed holes in the image.

**Dealing order.** One of `rowMajor`, `centreOut` or `random`
(`CompositeSpec.dealSequence`). With `centreOut`, the image grows from the
middle, which reads well on a projector; a tie goes to the lower slot. `random`
is a shuffle seeded from the assignment's ID, so one assignment always deals in
one order.

**More students than slots.** Deal a second round. Two students then own the
same slot, and the composite shows the latest passing contribution.

**Delivery.** The slot is the input `composite_slot` in the per-student input
set, so a Python test reads `_ck["composite_slot"]` from `_ck_inputs.py`, and
each other language reads it from its own inputs file. For a grid layout, the
inputs also carry `composite_col` and `composite_row`, so a test script does
not repeat the grid arithmetic. The names are prefixed and reserved, so they
cannot collide with an instructor's own inputs; on a clash, the composite's
value wins. The worker job and the browser seed endpoint both merge them in, so
the two grading paths read the same values.

**The grading deal ignores the window.** It is the backstop, so a student
whose first submission comes after the window (under an extension, say) is
still dealt a slot.

**No language, no composite.** An assignment with no declared language has no
inputs file, so `ActivityAuthoring` refuses a class composite on it
(`compositeNeedsLanguageMessage`). If the language is later changed to none,
grading still runs and leaves the slot inputs out: grading never fails.

**Staff.** A validation run, and any run by course staff or an admin, get the
reference slot (slot 0) and are never dealt a slot: a dealt slot is a
student's. A staff member's own submission is stored as a student submission,
so `CompositeSlots.gradingInputs` checks the course role on both grading paths.
Opening the page as staff deals nothing.

**A partition dataset uses the slot.** On a class composite, the deal number
of a partition dataset is the student's slot, so a student whose part count
equals the slot count holds the rows of their own tile
(docs/datasets-course-library.md §4.11).

**The MCP lock reads the owner pool.** The least-privilege MCP database role
cannot read `composite_slots` (it maps students to slots), and it reads
`submissions` filtered to validation runs. So `set_activity` answers both lock
questions on `ToolContext.mainDB`. This also corrects the existing kind lock,
which on the MCP pool saw no student submissions.

### 3. Ingest (slice 4)

`CompositeContributions.record` (`Sources/APIServer/Services/`) runs in
`ResultIngestEffects.apply`, which both ingest paths (the worker report and the
browser result) call. For a student's graded submission to a `classComposite`
assignment:

1. Take the first contribution in suite order. A script reports one; a second
   is ignored.
2. Check the payload again, because a browser-posted outcome is not trusted:
   the width, height, frames and format are the assignment's shape, and `data`
   is valid base64 of exactly the right length, at most 64 KB. An invalid
   payload is discarded with a log line. The grade does not change.
3. Upsert one row in `composite_contributions`: assignment, student, slot,
   submission, submitted-at, the pixels, and whether the test passed. One row
   for each student. A newer submission replaces the row; an older submission,
   re-tested later, does not.
4. If the test passed, insert the coverage item `slot-<n>` into
   `class_item_coverage`. The unique constraint keeps the first, so this is
   idempotent, and a later failure does not take the slot back.

Only a student's own submission records a contribution. Staff render the
reference slot and hold no dealt slot. A student with no dealt slot (the
grading deal failed) records nothing, with a log line.

**The class goal.** An unscoped `itemsCovered` goal counts the slot items
(`TestProperties.compositeCoverageItems`), so "the class fills 40 of 48 tiles"
is an ordinary union goal. A section-scoped goal does not count them: a slot
belongs to no section. The instructor's coverage table lists the slots in slot
order.

**Deletion.** Rows follow their assignment, their student and their submission
on delete. `deleteCourse` also deletes the slots and the contributions of the
course explicitly, as it does the coverage rows. The least-privilege MCP role
cannot read `composite_contributions`.

### 4. The composite view (slice 5)

The leaderboard page shows the composite stage when the aggregation is
`composite` (`CompositeStage`). The image data comes from a JSON endpoint, so
the HTML stays small and the canvas is never replaced:

```
GET /testsetups/:testSetupID/composite?since=<cursor>
```

`CompositeSnapshot` returns the state of every slot that is not empty, the
pixels of each slot that changed at or after the cursor, a new cursor, and the
count of complete slots. It uses an ETag over the body, with sorted keys, so an
unchanged poll is one 304. Staff receive every dealt slot, with each holder's
class handle; present mode passes `present=1` and receives no handles, because
the room reads the wall. A student receives only their own slot.

The canvas is outside the polled HTML region, because a region swap would
replace it. Its frame polls the JSON through the `json` mode of
`table-poll.js`, so it keeps the shared poll rules: the background-refresh
header, no poll in a hidden tab, and the conditional request.
`class-composite.js` draws each body that arrives. The region keeps its own
poll and shows the progress line and, closed by default, the list of slot
holders: the slot, the holder's handle and name, and the state.

A slot shows its latest passing contribution. With none, it shows its latest
failed one, unless `showFailed` is off. With two students on one slot, the
latest passing one wins.

**Slot states.** Each slot has one of four states, so the class can see the
image while it is rendered:

| State | Display |
|---|---|
| Empty: no student has the slot | Blank, with a thin grid outline |
| Rendering: a submission for the slot is queued or grading | A pulse in the slot |
| Failed: the latest contribution did not pass | The output, with a red outline |
| Passed | The output, animated if it has frames |
| Reference: no passing contribution, with `emptySlots: reference` | The reference render, dimmed |

The rendering state comes from the submission status that the server already
stores (`pending`, `assigned` or `running`). No new grading signal is
necessary. One cell for each slot lies over the canvas (a grid layout) or in a
strip under it (`sequence` and `sum`). `class-composite.js` sets each cell's
state classes, and the stylesheet draws them.

**Live arrival.** A slot whose pixels change flashes gold once, so the room
sees each change.

**Compositors.** `class-composite-core.js` holds the drawing rules and runs
under node (`class-composite-core.test.mjs`). `tile` places each contribution
at its grid position. `gallery` uses the same placement. `sequence` shows one
slot at a time, in slot order. `sum` adds the contributions pixel by pixel and
scales the brightest sample to 255.

**Playback.** Pause and a frame slider, when the view moves. All slots use one
clock, so the full image moves together at the `frameRate` of the block.

**Present mode.** The stage takes the podium's place, as large as the screen
permits. The progress takes the clock's place: "Tiles complete, 31 of 48".

**Staff view.** The leaderboard page is staff-only for this kind. The holder
list under the image names who holds each slot; a cell's tooltip repeats it.

**Student view: their own contribution only.** The full composite is for the
projector. A student does not see the composite on their own device. Instead,
the result page shows the submission's own contribution (`CompositeTilePanel`),
drawn by the same `class-composite.js` code at a larger scale, with its place
("Your tile: column 3, row 5") and its state. The pixels come from the stored
result, so the panel needs no poll. A student sees what they added to the image
on the screen, and checks it before they look up.

The leaderboard page is staff-only for this kind: `ActivityAuthoring` refuses
`leaderboardVisibility: visible` on a class composite
(`compositeLeaderboardHiddenMessage`), and the edit page shows no visibility
toggle for it.

**UI rules.** The page JS is in `Public/class-composite.js` and
`Public/class-composite-core.js`, with no inline script (#1516). The JS draws
pixels into the `<canvas>` and toggles classes for the slot states. It makes no
other styling decision. The `composite-*` classes are in the component
vocabulary in `docs/ui-design.md`.

## Source data and slot count

### Source data

The instructor does not upload a separate "base image". The data that the
students and the grader work on is one of these, and both already exist:

- **A file in the test setup.** For example, a scene description, a CT phantom
  volume, or an X-ray that the class filters tile by tile. Support files and
  datasets already carry this. The student's notebook reads the file, and the
  test script reads the same file.
- **The reference solution.** The complete target image is the output of the
  reference solution for every slot. A staff action, "Prepare reference"
  (slice 6), runs it once before the session and stores one reference render
  for each slot.

**Empty slots: blank or reference.** One display setting, `emptySlots`, decides
what the projector shows in a slot that has no passing contribution:

- `blank` (the default): the empty grid outline.
- `reference`: the stored reference render for that slot, dimmed. The class
  sees the target from the start, and their own work replaces it. This also
  fills the holes that a small class leaves.

There is one source of reference renders and one setting that shows them, so
"fill" and "backdrop" are the same thing, not two features. `blank` is the
default for two reasons. A reference render is a visible answer on a projector
that the whole class shares, and a wrong tile is harder to see next to correct
reference tiles than on an empty grid.

`reference` is refused at save for `sum`. In a `sum` composite, a slot is one
projection angle, and an empty angle is not a hole: it makes the
reconstruction blurrier, which is the lesson. Filling it with the reference
angle would hide that lesson.

**How the reference render is made (slice 6a).** The "Prepare reference"
button is in the composite settings on the edit page. It needs a reference
solution, and only an instructor can press it. For each slot, it makes one
`compositeReference` submission of the solution, owned by no student, and one
row in `composite_references` that names the slot. The worker gives the job
that slot's inputs, as it does for a student. The job waits behind every job
that a person waits on, with the class corpus run. When the result arrives,
the row stores the pixels and whether the run passed. A payload with the
wrong shape clears the row. A second press deletes the earlier rows, and the
earlier jobs that no runner holds, and starts again. A job that a runner holds
finishes and records nothing. Two presses at the same time cannot both save:
the second one gets an error and the earlier render stays. The edit page shows
"N of M slots ready".

The render has no student seed, so `=` expressions resolve as they do with no
seed, and the solution is personalized once for all slots. The render does not
follow later changes. After a change to the solution, the shape or the
compositor, press "Prepare reference" again.

The projector shows a render only in a slot that shows no contribution. A
failed contribution that shows (`showFailed: true`) keeps its slot, so the
dead pixel stays visible. A render never counts as a completed slot, and it
never covers anything. The student view never shows a render, because a
render is a visible answer. A render whose length is not the shape of the
spec is not shown, so a render made before a shape change disappears until
the instructor prepares it again.

**Spare slots (slice 6b).** A student whose own tile passed can fill a hole.
The result page shows a "Fill a hole" button while the session is open, none
of the student's spares is grading, and a hole is left. A hole is a slot with
no passing contribution and no spare that passed or is grading. A slot that no
student holds comes first, so a spare does not race a student who may still
submit. Then come the slots whose holder has not passed. In each group, the
holes follow the deal order. A slot where the student's own spare failed is
not offered to them again, because the same code fails there again; it stays
a hole for the others.

On a composite that runs once per lab group, a student fills holes in the
image of their own lab, and only while they play in that lab's open session
(`docs/lab-groups.md`, slice 4b). The spare's row is in
`group_composite_spares`, and a passing one covers its slot in the lab's
coverage (slice 5b).

The button grades the student's passing submission again with the inputs of
the first hole. The job is a `compositeSpare` submission, owned by no student,
so no listing, grade or attempt count sees it. Its row in `composite_spares`
names the student, and a user delete removes the job and its copy of the code.
The job grades the file as the student submitted it, with the student's own
seed pinned at the request, so it runs with the values their own run had. The
worker claims it behind every student job, before the corpus run and the
reference jobs. A spare is grading until its result is recorded; a job that
no runner can take waits, as a student's own submission would.

A passing result fills the slot and covers it for the student, so it counts
toward an `itemsCovered` goal. When the slot's holder passes later, their own
tile takes the coverage back. A failed result leaves the hole open, and the
next request from another student replaces it. The page offers one spare at a
time, and there is no cap on how many holes one student fills. Two students
who ask at the same moment get different holes.

On the projector, a passing spare shows in its slot as a passed tile with the
name of the student who made it. It replaces a failed contribution there,
because a classmate has filled that hole. A passing contribution always wins
over a spare. A student's view of the composite never shows spares; their
result page lists their own spares, each with its state.

### Slot count

**The instructor sets the slot count at authoring.** It is `cols × rows` for
`tile` and `gallery`, and `count` for `sequence` and `sum`. The count does not
come from the roster or from attendance.

**The layout locks at the first deal or the first student submission,
whichever comes first.** Slots are dealt when a student opens the page, which
can be before any submission, so a lock at the first submission would come too
late: a smaller layout would leave dealt slots outside the grid. Each student's
slot and the size of each contribution depend on the layout, and the grader
checks that size.

`compositor`, `layout`, `contribution` and `dealOrder` lock together
(`CompositeSpec.hasSameStructure`). The compositor is in the set because a
change between a grid and a count moves every slot. This is a new check in
`ActivityAuthoring`, with its own refusal message
(`compositeLayoutLockedMessage`). The kind lock does not cover it: that check
compares only the kind, and its message says that the kind is locked. The edit
page disables the structural inputs under the same rule
(`ActivityAuthoring.compositeStructureLocked`).

**A new composite starts from `CompositeSpec.starter`:** a 6 × 8 grid of
8 × 8 still RGB tiles. Choosing the kind on the edit page or with
`set_activity` and no block seeds it, so the kind select alone makes a valid
activity. A compositor change between a grid and a count keeps every slot
(`CompositeLayout.reshaped(forGrid:)`): a grid becomes its slot count, and a
count becomes the smallest near-square grid that holds it.

**Size the layout for the expected attendance, not for the roster.** The
authoring control shows the ratio, for example "Roster: 62. Slots: 48 (77%)."
Second-round dealing handles a larger attendance. For a smaller attendance,
`emptySlots: reference` shows the reference in the holes, and spare slots let
students who finish fill the holes with their own work.

The effect of too few students depends on the compositor:

| Compositor | Slot count is | When fewer students attend |
|---|---|---|
| `tile` | The grid | The image has holes |
| `sequence` | The number of frames | Frames are missing |
| `sum` | The number of projection angles | The reconstruction is complete but blurrier |
| `gallery` | The number of panels | Panels are empty |

For `sum`, a small class degrades naturally, and the blur itself shows how the
number of angles controls the quality of a CT image.

**For `tile`, more slots do not give a larger image.** The full image is
`cols × w` by `rows × h` pixels. To add slots at the same image size, make each
contribution smaller.

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
    "showFailed": true,
    "emptySlots": "blank"
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
| `emptySlots` | `blank` (default) or `reference`: what a slot with no passing contribution shows. `reference` needs the reference renders, and is refused for `sum`. |

`ActivityAuthoring` refuses a block at save when a field is missing or out of
range, or when the total payload for all slots is more than 4 MB.

## Compatibility rules

| Seam | Rule |
|---|---|
| Suite rebuilds | `makeWorkerManifestJSON(preserving:)` already keeps the `activity` block. `AssignmentHelpersManifestTests` gains a composite round trip. |
| Layout lock | `compositor`, `layout`, `contribution` and `dealOrder` lock at the first deal or the first student submission, whichever comes first (`compositeStructureLocked`). This is a new check with its own message, separate from the kind lock. `frameRate`, `showFailed` and `emptySlots` are display settings and stay editable. |
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
   aggregation, the `composite` block, the save-time checks, the layout lock,
   the edit-page control with the roster ratio, and `set_activity`.
3. **Slots.** `composite_slots`, dealing in the three orders, the slot in
   `gradingInputs`, the `activity-composite` capability token, and the
   extension of the layout lock to the first deal (slice 2 can lock only at
   the first submission, because no slot is dealt before slice 3).
4. **Ingest.** `composite_contributions`, the payload checks, the coverage row,
   and `deleteCourse`.
5. **The composite view.** The JSON endpoint, `class-composite.js` with all
   four compositors, the four slot states, playback, present mode, the
   student's own-contribution panel on the result page, the node tests,
   `ui-review`, and the `composite-leaderboard` and `composite-tile`
   visual-regression pages.
6. **Reference renders and spare slots.** "Prepare reference" is a staff
   action that renders the reference solution for every slot and stores the
   results. It is a server-initiated job that waits behind every student
   submission, with the claim-order rule of the corpus run. The slice also
   enables `emptySlots: reference`. Shipped as 6a.
   6b. A spare slot is a second slot that a student who finished can ask for,
   to fill a hole. The student presses "Fill a hole" on the result page. The
   server grades the latest passing submission of the student again with
   the inputs of an empty slot, behind every student job, and the tile is
   credited to the student. Shipped as 6b.

## Risks

- **Polling load.** Only the projector polls the full composite, and it is one
  client. A student page polls only for its own contribution, at a slower
  rate. The ETag and the `since` cursor make an unchanged poll cheap.
- **Payload size.** 48 slots with 30 RGB frames of 8 × 8 pixels is about
  280 KB of pixels in total, or about 370 KB as base64. The cap for each
  contribution and the 4 MB limit at save keep this small.
- **Test time.** A test renders only the student's slot, not the full image,
  so it stays well below the 10-second limit.
- **Attendance.** Dealing at arrival handles absent students. Reference
  renders (slice 6a) fill the holes of a small class, dimmed. Spare slots
  (slice 6b) let students fill them with their own work.

## Decisions

All open decisions are settled.

1. **The composite is for the projector.** Each student sees only their own
   contribution (see **Student view**).
2. **Failed contributions show with a mark by default** (`showFailed: true`).
   The dead pixel is part of the lesson.
3. **Spare slots ship in slice 6**, with the reference renders.
4. **`emptySlots` defaults to `blank`.** A reference render is a visible answer
   on a shared projector.

## Activities this enables

| Activity | Compositor | Available after |
|---|---|---|
| The class is the GPU: each student shades one tile of an animated scene | `tile` | slice 5 |
| Cine loop: each student gates one cardiac phase | `sequence` | slice 5 |
| Class film: each student renders one segment of a fly-through | `sequence` | slice 5 |
| The class is the CT scanner: each student backprojects one angle | `sum` | slice 5 |
| Teleradiology race: each student streams one scan over a slow link | `gallery` | slice 5 |
