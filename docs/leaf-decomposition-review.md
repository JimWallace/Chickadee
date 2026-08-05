# Review: what the corrected Leaf rule unblocks

A second-opinion review answering three questions handed over after #1266:
what does the corrected Leaf rule make possible that the old one forbade,
is the `assignment-new` / `_assignment-edit-body` duplication worth removing,
and if so in what order.

Short version: the corrected rule is real and verified, but it unblocks less
than the old rule appeared to be holding up. Measured against actual diffs,
the Leaf-partial opportunity across those two templates is **one block, about
70 lines**. The duplication that is actively costing correctness is
**JavaScript**, and the Leaf rule was never what blocked removing it. Two
live, user-visible defects trace directly to it.

---

## 1. The rule, re-verified

#1266 established that multiple inline partial includes work and that the
old "at most one" rule was a misdiagnosis. It explicitly did not test how
many includes one template tolerates. The plan below needs more than one
include inside an `extend`/`export` block on a page that also extends
`base`, which is a configuration #1266 did not cover, so it was verified
here, control-first, per the method in the brief.

| Step | Result |
|---|---|
| **Control** — `AssignmentRoutesPublishTests/newAssignmentPageWiresSuiteTableJS`, unmodified | `Test run with 1 test in 1 suite passed`, with a real `GET /instructor/new` in the log |
| **Probe** — two trivial partials added alongside the existing `_family-editor-body` include in `assignment-new.leaf` (three inline includes total, inside `extend("base")` + `export("content")`), asserting both markers appear in the response body | **passed** |
| **Falsify** — one include removed | **failed with exactly 1 issue**, the assertion for the removed marker; the other still passed |

Three inline includes inside an extend/export block resolve. LeafKit 1.14.3,
same pin the brief verified against. Probe artifacts were removed; the tree
is clean.

One trap worth recording, because it is the one that produced #1266's wrong
answer in a slightly different costume. Every run prints this first:

```
Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
```

That is the XCTest shim, not the result. The line that matters is the Swift
Testing summary underneath it. A harness that greps for a pass marker can
match the shim line and report success on a filter that named nothing.

---

## 2. What the diffs actually show

The brief's marker counts are accurate but they overstate shared structure,
which is exactly what it warned about. For `suite-sections`, 9 occurrences on
the create page and 6 on the edit page reduce to the **same five structural
sites** on each once comments and JS string literals are excluded.

### (a) The suite-sections block — the one genuine partial candidate

`assignment-new.leaf:276-347` against `_assignment-edit-body.leaf:301-385`.
Diffed in full. Every difference:

- three comment blocks present only on the edit side (13 lines, no semantics)
- three URL differences — the rename, delete, and variables actions, which are
  `/instructor/new/draft/suite-sections/...?draftID=X` versus
  `/instructor/#(assignmentID)/suite-sections/...`
- `data-ck-inplace` on the edit side's rename form

Everything else — the section header, drag handle, view/edit modes, the
inputs table, the ungrouped toolbar, the table shell — is character-identical.
About 70 lines that a partial could carry on one base-URL parameter and one
boolean. This is a low-risk share, and it is the only one in these two files.

### (b) The files table — do not share

`notebook-files-table` appears once in each, and the brief's caution applies:
the marker is a signal, not proof. Only the `<thead>` (6 lines) and the
support-file `#for` rows (12 lines) are common. The two notebook rows differ
structurally, not cosmetically:

| | create | edit |
|---|---|---|
| assignment notebook | may not exist — Upload / Create Blank / Clear, driven by five hidden `draftAction` submit buttons | always exists — a single Edit link |
| solution notebook | Upload / Create Blank / Create from Assignment | Edit link, or a `create-solution` form POST |
| workbench | absent | `data-wb-file` hooks on both Edit links |

A shared partial here would be mostly branch. That is precisely the "gets the
create-vs-edit differences subtly wrong" failure the brief flags, and it buys
18 lines.

### (c) The seeds and banners

Four seed `<script>` tags, identical, 4 lines. Error and notice banners, 12
lines, differing only in the `<h2>` text. Neither justifies a partial.

**Honest total for the Leaf work: roughly 70 lines of one block out of the
1,977 lines in the two files — about 4%.**

---

## 3. The duplication that is actually costing something

None of the following was ever blocked by the Leaf rule. All of it is
JavaScript, and in every case examined **the create page is the stale copy** —
the edit page received the fix and the create page kept the fork. That
asymmetry is consistent enough to be the thing worth guarding against.

### Finding 1 — `checkUWDates` is duplicated and has already drifted

`assignment-new.leaf:986-1011` and `_assignment-edit-body.leaf:635-660` —
and, found during implementation, a third copy at `assignments.leaf:1117`.
Same function, three copies, drifted on two axes: only the edit copy guards
`warningEl` against null, and the dashboard copy uses a shorter user-facing
label (`Near:` rather than `Due date is near:`). This is the drift risk in its
finished form, not as a hypothetical.

### Finding 2 — per-student `=` expressions silently degrade on the create page

The edit page dropped its inline section-inputs JS in v0.4.160 for
`inputs-editor-core.js` + `section-inputs-editor.js`. The create page still
carries roughly 270 lines of the pre-extraction inline version. The chain,
each link checked in source:

1. Both pages render section inputs through the **same** server helper,
   `suiteSectionShellRows`, which emits a per-student expression as a row
   whose value is `= <source>` (`PublishedAssignmentRoutes+Suite.swift:297-301`).
   The create page reaches it via `newAssignmentSuiteSectionShellRows`.
2. The shared module classifies that row as an expression —
   `classifyValue` branches on a leading `=` (`inputs-editor-core.js:36`).
3. The create page's inline `tryParseValue` has no such branch. Executed
   directly, `tryParseValue("= seed % 26")` returns
   `{ok: true, value: "= seed % 26", strict: false}` — a bare string.
4. Its `buildPayload` therefore emits `{variables: [...]}` with **no**
   `expressions` key.
5. The draft endpoint coalesces the missing key:
   `expressions: body.expressions ?? []`
   (`DraftAssignmentRoutes+Sections.swift:102`). The server supports
   expressions on this path; only the page does not send them.

So an instructor who types `= seed % 26` into a section input on the Create
Assignment page — the documented syntax, and the exact string used as the
placeholder in the Global Inputs box on the edit page — gets a literal string
named `x` whose value is the text `"= seed % 26"`. On the edit page the same
keystrokes create a per-student expression.

Nothing catches it. `DraftSuiteSectionRoutesTests` has 9 tests, none touching
expressions. `SectionInputsTests` covers expressions only at the model and
manifest layer, never through the create page's HTTP path.

### Finding 3 — the create page double-binds section handlers, and one binding posts to the wrong URL

`suite-table.js` is loaded by **both** pages and already handles section
rename toggle, section delete, and section drag-reorder (lines 1232, 1246,
1256, and the drop handler at 983). The create page binds its own inline
handlers for all three on top: the toggle/cancel/delete set on `document`
(`assignment-new.leaf:639`), the drag set on `#suite-sections` (line 677) —
the same element `suite-table.js` resolves as its `container` (line 118).

Both fire. Two consequences:

- **Section delete raises two confirm dialogs**, with different wording, and
  both handlers build and submit a form.
- **Section drag-reorder raises a spurious failure alert.**
  `persistSectionOrder` derives its endpoint by string-replacing the suite URL:
  `(urls.putSuite() || '').replace(/\/suite$/, '/suite-sections/reorder')`
  (`suite-table.js:1097`). On the edit page `putSuite()` returns
  `/instructor/<id>/suite`, the anchor matches, and the result is correct. On
  the create page it returns `/instructor/new/draft/suite?draftID=<id>`, which
  does not end in `/suite`, so the replace is a no-op and the POST goes to the
  suite endpoint — registered `GET` and `PUT` only
  (`DraftAssignmentRoutes.swift:36-37`). The 405 rejects, and the instructor
  sees `Section reorder failed: ... Reload the page to recover.`

  **The inline handler did not cover for it.** Its POST read a `draftID` that
  was declared only inside sibling IIFEs (`assignment-new.leaf` had four such
  declarations, at the pre-fix lines 390, 423, 769, and 927, none in the
  handler's scope). Under the block's own `'use strict'` that is a
  `ReferenceError`, thrown after the DOM reorder and before the request. So
  the list reordered on screen, neither request reached the server, and the
  order reverted on reload — with a failure alert on top.

Confidence: the mechanisms are traced end-to-end in source, not confirmed in a
browser. Render tests would not catch either, since they do not exercise page
JS. A smoke check should confirm both before and after the fix.

---

## 4. Recommendation

**Yes, remove the duplication — but invert the implied order.** Do the
JavaScript consolidation first, because it deletes two live defects and about
300 lines. Do the one Leaf partial last, because it is the least valuable of
the four slices despite being the one the old rule blocked.

Stated as a risk judgement, since these are the two highest-traffic authoring
surfaces:

- **Low risk, do it:** the suite-sections block. Fully diffed; the only
  differences are one URL prefix and one attribute.
- **Low risk, do it:** all three JS consolidations. Two of them delete code
  in favour of modules the edit page already proves in production, and
  `section-inputs-editor.js` is URL-agnostic — it reads `form.action` and
  selects on `form.section-vars-form` / `button.section-var-add`, all of
  which the create page already renders identically.
- **High risk, do not:** the files table, the page skeleton, or any attempt
  at a single create-or-edit template. The differences there are deliberate
  and structural. Two honest copies beat a partial that is mostly branch.

Also out of scope: `assignments.leaf` (1160 lines) and `admin.leaf` (718).
They are large, but they are not duplicated against anything. Size alone is
not a reason to decompose, and the brief's line-count table invites that
conflation.

---

## 4a. What implementing it changed about the above

All four slices shipped on this branch. Three corrections to the analysis,
recorded because the estimates above are what someone would plan against:

- **`checkUWDates` had three copies, not two** — the dashboard publish form
  carried a third, with a different label. The hoist takes the label as a
  parameter so no visible text changed.
- **Section drag-reorder was fully broken on the create page**, not
  half-covered. See Finding 3: the inline handler's `draftID` was out of
  scope, so its POST never fired either.
- **Two guards caught their own documentation.** The suite-table absence
  check matched the old pattern quoted in a comment, and the create-page
  form assertion matched the marker attribute named in the new partial's
  comment. The first was fixed by describing the pattern instead of quoting
  it; the second by parsing form open tags, which is what
  `InstructorWorkbenchRoutesTests` already does for exactly this reason. Both
  are the same shape as the Leaf-comment finding this branch started from:
  a scanner that cannot tell markup from prose about markup.

Net: `assignment-new.leaf` went from 1,059 lines to 711, and `_assignment-edit-body.leaf` from 918 to 811. The Leaf partial
accounts for 72 of those; the rest is JavaScript that moved to modules both
pages already shared.

## 5. Slice plan

Smallest first. Each is independently shippable, and each carries an
assertion that must be **seen to fail** before it is kept.

### Slice 1 — hoist `checkUWDates` into `chickadee-ui.js`

Two copies to one; adopt the edit page's guarded version. Delete both inline
definitions.

- **Assertion:** a `Tests/BrowserRunnerJSTests` case that the function does
  not throw when `warningEl` is null, plus render assertions that neither
  template still defines it inline.
- **Falsify:** drop the guard and confirm the first goes red; re-add an
  inline definition and confirm the second does.

### Slice 2 — create page adopts the shared inputs modules

Delete the ~270-line inline block; add the two `<script src>` tags the edit
page already uses. This closes Finding 2.

- **Assertion:** POST `= seed % 26` through
  `/instructor/new/draft/suite-sections/:sid/variables` and assert the
  manifest round-trips it as an **expression**, not a literal; then GET
  `/instructor/new` and assert the row re-renders as `= seed % 26`.
- **Falsify:** revert the JS swap and confirm the round-trip assertion fails
  with the value landing in `variables`.
- **Note:** write this assertion *before* the fix — it should fail against
  today's `main`. That is the cleanest possible falsification, and it also
  documents the bug.

### Slice 3 — delete the create page's inline section handlers

Remove the toggle/cancel/delete and drag-reorder blocks; let `suite-table.js`
own them, as it already does on the edit page. Fix `persistSectionOrder` to
take an explicit `reorderSections` URL builder in `urls`, matching how
`putSuite` / `deleteScript` / `uploadScript` are already passed, rather than
string-replacing the suite URL. This closes Finding 3.

- **Assertion:** a JS unit test on the URL builder for both page shapes
  (query-string draft form and path form), plus a route test asserting POST
  to `/instructor/new/draft/suite` is not an allowed method — which is what
  made the regex wrong.
- **Falsify:** restore the regex derivation and confirm the draft-shape case
  goes red.
- **Browser check required.** This is the drag-and-drop path and render tests
  do not reach it. Run the smoke harness, and mind the brief's warning about
  assertions that pass against a `chrome-error://` page.

### Slice 4 — extract `_suite-sections.leaf`

The one Leaf partial. Both pages include it; it takes a section base URL and
a flag for the in-place form attribute. Verified above that the create page
tolerates the extra include.

- **Assertion:** render `/instructor/new` and the edit page, and assert the
  section markup appears **with the correct per-page action URLs** — not
  merely that the block is present.
- **Falsify:** point the partial at the wrong base URL and confirm the
  create-page assertion fails while the edit-page one still passes. Asserting
  only presence would survive that, which is the whole point.
- Pair with the same smoke check as Slice 3, for the same reason.

### Not planned

Sharing the files table, the page skeleton, or the seed tags; decomposing
`assignments.leaf` or `admin.leaf` under this heading.

---

## 6. Note for `CLAUDE.md`

The near-term roadmap entry still frames this as "Leaf partial decomposition —
UNBLOCKED", which reads as though a large decomposition is waiting. It is
worth amending to say that the decomposition itself is roughly one partial,
and that the substantive create-versus-edit drift is JavaScript. Otherwise
the next person inherits the same overestimate this review was asked to check.
