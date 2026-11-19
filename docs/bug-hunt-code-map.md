# Bug Hunt Code Map

**Status: built 2026-11-10.** The maintainer chose line ranges, a projector-only
board, and a percentage-only board for Bug Hunt 2. Line coverage (section 3)
is not built.

## The goal

In a bug hunt, the class writes tests together against one reference codebase.
The class covers the codebase as a group. The display for this activity is the
reference code itself on the projector: each part of the code lights up when
the class's combined tests cover it. The parts that stay dark show the class
where work remains.

HLTH 230-W27 has two bug hunts that need this: Bug Hunt 1 (`Da8dat`, blood
pressure categories) and Bug Hunt 2 (`tVt2Hi`, dosage rules). Both are typed
`classActivity` and have no `activity` block yet (`docs/assignment-types.md`,
decision 3).

## What exists

Most of the bug hunt is already shipped (`docs/collaborative-class-assignments.md`).

- **A contribution assignment.** The starter notebook declares slot cells.
  A student's latest submission is their contribution. No manifest field marks
  it; `declaredSlotCount > 0` does.
- **Items.** An item is a passing suite entry, for example one test that runs
  the class's tests against one seeded bug variant. `class_item_coverage`
  records the first student to cover each item (one row per item, first finder
  wins). Per lab group, the same rows go to `group_class_item_coverage`.
- **The class corpus run.** All contributions, merged into one notebook, are
  graded as one `classAggregate` submission. The run produces one number, the
  coverage fraction. It runs only when the manifest has a `classCoverage` goal,
  and only on the native worker.
- **Display.** A class goal line on each student's submission page, and an
  instructor table of items (found, first finder, when). There is no projector
  view, because the leaderboard and present mode require an `activity` block.
- **The live composite view** (`docs/class-composite.md`) shows that a
  projector page can poll a JSON snapshot every 5 seconds with an ETag, so an
  unchanged poll costs one 304.

The gap is small: an `activity` kind for the bug hunt, and a view that maps
covered items onto the code.

## Proposal

### 1. The `bugHunt` activity kind

`docs/class-activities.md` listed a `bugHunt` kind, but `ActivityKind` in code
did not have it. It is added with an aggregation of its own:

- `ActivityKind.bugHunt`, aggregation `coverage`, opponent source `none` (the
  seeded variants are ordinary suite entries, so the runner needs nothing new).
- It requires a contribution assignment (a starter with slot cells). It is
  refused at save time otherwise.
- It gives the bug hunt the leaderboard and present-mode pages, and so a
  projector view.

### 2. The `bugHunt` block

The block lists the items, and may carry the code to show:

```json
"activity": {
  "kind": "bugHunt",
  "bugHunt": {
    "items": ["publictest_bug_01.py", "publictest_bug_02.py"],
    "code": "def bloodPressure(systolic):\n    ...",
    "regions": [
      { "item": "publictest_bug_01.py", "lines": "12-13" },
      { "item": "publictest_bug_02.py", "lines": "14-15" }
    ]
  }
}
```

- `items` are suite entries, named by script filename as `get_suite` lists
  them. Each must be in the suite. The board's percentage is the share of these
  that the class has covered, rounded down, so 100% means every item.
- `code` is a copy of the code the students test, kept in the block. In the
  HLTH 230 bug hunts that code is a notebook cell, not a file, so the block
  holds its own copy. Its seeded buggy variants are separate files and are
  never shown. At most 400 lines and 32 KB.
- Each region ties an item to a line or an inclusive range of lines, 1-based.
  The ranges are checked against the code at every save.
- With no `code`, the board shows the percentage alone. Bug Hunt 2 runs this
  way, so the class has to coordinate in the room.
- Choosing the kind with no block seeds `items` with every suite entry that no
  other entry depends on. In a bug hunt the gate that checks the class's tests
  against correct code is a prerequisite of each bug's entry, so the seed is the
  bugs.

A line is dark while every region on it is uncovered, partial while some are
covered, and lit once all are. A region is covered when `class_item_coverage`
has its item, under the runner's outcome name for the script. Nothing new is
stored.

**The board.** Present mode shows the percentage in large type, the count
("7 of 10 covered"), and the code map when there is code. It renders inside
present mode's polled region, so it refreshes every few seconds with no script
of its own. The staff leaderboard page shows the same board. Students never see
either: a bug hunt's leaderboard is refused as "visible", as a class
composite's is.

**No names on the projector.** The board shows what is covered, not who
covered it. The instructor's item table on the submissions page keeps the first
finder, as it does now.

**What it costs.** No runner change, no RunnerCore change and no new table. It
works for browser and worker grading alike, because `class_item_coverage` is
written by both ingest paths.

### 3. Line coverage (later, optional)

The code map lights the parts that the instructor anchored. True line coverage
would light every line that the class's tests execute, with no authoring. It
needs three things that do not exist:

- A tracer in the test runtime. The runner image has no `coverage` package. The
  standard library's `sys.monitoring` (Python 3.12) or `trace` would serve, but
  neither is used anywhere yet, and neither is confirmed in the xeus-python
  kernel.
- A way to return line data. The only structured channel larger than a number is
  the `composite` footer field (64 KB of pixels), and the collaborative design
  rejected a general payload channel. A new footer key is a change to the
  RunnerCore output contract and `Tests/Fixtures/output-contract.json`.
- The corpus run, which is worker-only. So line coverage would update once per
  corpus run, not on each submission.

The recommendation is to build the code map first and treat line coverage as a
separate decision after the class has used it.

## Decisions

Decided by the maintainer on 2026-11-10.

1. **Anchor by line range.** Function names would survive edits but need a
   parser per language.
2. **Projector only.** Students do not see the board, so the room is where the
   class coordinates.
3. **Bug Hunt 2 shows the percentage alone.** Its block has no code.
4. **Line coverage (section 3) waits** until the class has used the code map.

## Setting up a bug hunt

1. The starter notebook declares contribution slots, and each bug is one suite
   entry that depends on the gate.
2. `set_activity` with kind `bugHunt`. The seed lists the bugs.
3. For a code map, call `set_activity` again with the `bugHunt` block's `code`
   and `regions`.
4. Open the leaderboard page and choose Present.
