# Assignment versioning and recovery — design

**Status:** planning (decisions locked, not yet implemented).

Every persisted change to an assignment's *content* records an immutable
snapshot. Snapshots are never deleted. A course-staff member — via MCP, in this
first cut — can list an assignment's history, read any past version without
disturbing the live one, and restore one when an edit goes wrong.

This exists because agent-driven authoring makes content edits cheap and fast,
and a fast wrong edit is indistinguishable from a fast right one until a student
hits it. Today there is no way back: `applyPatternFamilies` overwrites the
manifest, the zip is repacked in place, and the previous bytes are gone.

---

## 1. What gets versioned

An assignment's content is exactly three artifacts:

| Artifact | Where it lives | What it carries |
|---|---|---|
| `manifest` | `test_setups.manifest` (TEXT) | suite list, pattern families, notebook checks, test-suite sections, global inputs, section variables, datasets, achievements, time limit, grading mode, language |
| setup zip | `testsetups/{setupID}.zip` | test scripts, support files, `solution.ipynb`, dataset files |
| starter notebook | `testsetups/{setupID}.ipynb` | the notebook students open |

Everything else is **derived** and re-materializes from those three:
`shared/{setupID}/` (via `extractSupportFilesToSharedDirectory`),
`shared/{setupID}/solution.py` (via `SolutionNotebookExtractor.writeSolutionPy`),
per-student notebook materializations, `TestSetupCache` entries on the runner.
A snapshot therefore needs the three artifacts and nothing more.

Assignment **metadata** — title, due date, visibility, slug, course section,
BrightSpace grade-item mapping — lives on `assignments` and is deliberately *not*
content. It is recorded in a snapshot for reference but never written back by a
restore (see §5).

Student data is never involved. Snapshots hold instructor-authored content only.

---

## 2. Storage

### 2.1 `assignment_versions`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `test_setup_id` | string | **No foreign key** — see §7.1 |
| `assignment_id` | UUID? | denormalized for lookup; nullable so history outlives a deleted assignment |
| `course_id` | UUID | FK → `courses.id`; the scoping and purge key |
| `version_number` | Int | monotone per `test_setup_id`; unique index on `(test_setup_id, version_number)` |
| `manifest` | TEXT | full manifest JSON, stored inline |
| `manifest_hash` | string | `manifestHash(_:)`, the existing helper |
| `file_map` | TEXT | JSON object, zip entry path → sha256 |
| `notebook_hash` | string? | sha256 of the starter notebook, nil when the setup has none |
| `snapshot_hash` | string | hash over `manifest_hash` + `file_map` + `notebook_hash`; the dedupe key |
| `actor_user_id` | UUID? | nil for system-originated snapshots |
| `actor_username` | string? | denormalized at write time, same reason as `audit_log` |
| `origin` | string | `mcp:update_suite`, `web:save_edit`, `clone`, `import`, `restore:7`, `baseline` |
| `summary` | string? | one short line, e.g. `pattern family "bmi": 2 cases changed` |
| `restored_from_version` | Int? | set when this version was produced by a restore |
| `created_at` | timestamp | |

### 2.2 Blobs

Content-addressed under `testsetups/versions/blobs/<first-2-hex>/<sha256>`.

Per **file**, not per zip. This is load-bearing: `/usr/bin/zip` embeds
timestamps, so repacking byte-identical content produces a different archive
every time — hashing whole zips would dedupe nothing at all. Hashing entries
means a 200-edit authoring session against a setup with a 3 MB dataset and an
untouched notebook stores those bytes exactly once. That is what makes "never
delete a version" affordable rather than a disk-fill incident.

The starter notebook is stored as a blob under its own hash, alongside the zip
entries.

Blobs are written before the row that references them and are only ever deleted
by the course-purge sweep (§7.4). A blob with any referencing row is never
removed.

---

## 3. When a snapshot is taken

### 3.1 Post-state, plus a lazy baseline

Snapshots record the state **after** an edit. So version *N* always names a
state that actually existed, and the newest version always equals current
content — which makes "restore to *N*" unambiguous and makes verification a
straight equality check.

The pre-edit state is captured by a separate `ensureBaseline` call made
**before** the mutation: it records the current state as `v1` (`origin:
baseline`) if and only if the setup has no history yet, and is a single indexed
count once it does. Without it, the first agent edit on every assignment that
predates the feature is precisely the one you cannot undo. It also avoids a
migration that would have to walk and hash every existing setup on disk at
deploy time.

So a capture point does two calls — `ensureBaseline` before the edit, `record`
after — and both are no-ops in the steady state.

### 3.2 Self-deduping

`AssignmentVersionStore.record` computes `snapshot_hash` from the current
on-disk and in-DB state and returns without writing when it equals the newest
version's. Two consequences:

- No-op writes (a save that changed nothing, a tool called twice) cost one hash
  and no row.
- Call sites can be **generous**. Over-calling is free; under-calling is the only
  real failure mode. This deliberately relaxes the precision required of the
  chokepoint work in §4.

### 3.3 Granularity

One version per content-changing write call. An agent session may produce
50–200 rows for a single assignment; with per-file blobs that is a few kilobytes
of rows and no new bytes. `list_assignment_versions` pages.

Coalescing bursts was considered and rejected: the step you most want back is
usually in the middle of an agent's run.

---

## 4. Capture points

Versions are recorded at the **service layer**, so web saves and MCP writes both
produce history. Only MCP gets tools to read and restore in this first cut, but
a history with browser-shaped holes would let a restore silently discard an
instructor's work — the exact failure this feature exists to prevent.

### 4.1 MCP

A `finalizeMCPWrite` step that every `content:write` tool funnels through.

This cannot piggyback on `finalizeContentEdit`: only eight tools call that one,
and `update_solution`, `update_global_inputs`, `update_section_variables`,
`set_dataset`, `set_time_limit`, `set_grading_mode` and the suite-section tools
deliberately do not — yet all of them change content that belongs in a snapshot.

A sibling to `MCPContentEditCoverageTests` classifies every `content:write` tool
as versioning or non-versioning by source scan, so a future write tool that
skips history is a build failure with instructions, not a silent gap. Same
discipline, same file shape.

### 4.2 Web

The known manifest/zip write sites, all in `APIServer`:

- `PatternFamilyApplication.applyPatternFamilies` — the shared manifest rebuild
  plus zip repack; reached from the suite editor, the new-assignment publish
  path, and `GlobalInputsService`
- `ScriptCRUDHelpers` — raw script create/update/delete
- `PublishedAssignmentRoutes+Datasets` — dataset marks
- `NotebookScaffoldHelpers` and `AssignmentAuthoringService.writeAssignmentNotebook`
  — starter-notebook saves, including the language re-derivation
- `SuiteEditHelpers` — the suite payload apply
- the solution-save path in `RunnerValidationHelpers`

Because `record` dedupes, these can be hooked incrementally without a correctness
cliff; a missed site shows up as a coarser history, not a wrong one.

### 4.3 Creation paths seed `v1`

`AssignmentAuthoringService.cloneAssignment`, `copyCourse`,
`AssignmentAuthoringService.createAssignment`, and `.chickadee` bundle import
each stamp a single `v1` with the appropriate `origin`. The §3.1 lazy baseline
covers any creation path missed here.

Hidden drafts (the new-assignment flow, setups with no published assignment) are
skipped — they accumulate edits that are not yet anyone's content.

---

## 5. Restore

`restore_assignment_version(assignmentPublicID, version)`:

1. Authorize: per-course `instructor` via `evaluateCourseWrite`; refuse on an
   archived course, same as every other write.
2. Materialize the snapshot's `file_map` into a temp directory from blobs, repack
   with `repackZipFromDirectory`, write the notebook, write the manifest.
3. Re-derive: `extractSupportFilesToSharedDirectory`,
   `SolutionNotebookExtractor.writeSolutionPy`.
4. Invalidate any instructor notebook working copy (§7.3).
5. Run `finalizeContentEdit` — close the assignment, manifest-gated regrade,
   re-kick validation. Restoring changes what is graded, so it takes the same
   path as any other content edit.
6. Record a **new** version, `v_{max+1}`, with `restored_from_version: N`.
7. Write an `AuditAction` entry — a restore is a real staff action.

History is linear and append-only. A restore never rewinds the counter, never
branches, never deletes, and is itself undoable by restoring the version before
it.

**Restores put back content only.** Title, due date, visibility, course section,
and BrightSpace mapping are left alone; the assignment lands closed, as any
content edit leaves it. A recovery action must never silently reopen an
assignment or move a deadline students have already seen. The snapshot still
records metadata, so the tool response can report what the title and due date
were at the time and the instructor can reapply them deliberately.

The response reports `submissionsRequeued` so the caller sees the blast radius:
restoring a suite regrades every existing submission on that setup.

---

## 6. MCP surface

Three tools; the catalog goes 47 → 50.

| Tool | Scope | Returns |
|---|---|---|
| `list_assignment_versions` | `content:read`, `.ta` | version number, `createdAt`, actor, origin, summary, `manifestHash`, `isCurrent`, `restoredFromVersion`, paged |
| `get_assignment_version` | `content:read`, `.ta` | the snapshot's manifest-derived suite shape and file list; optional `path` returns one file's body, so an agent can read an old script without restoring anything |
| `restore_assignment_version` | `content:write`, `.instructor` | new version number, `assignmentClosed`, `submissionsRequeued`, restored file count |

`get_assignment_version` reuses `get_suite`'s authorization exactly. Snapshots
contain secret-tier tests and reference solutions; the MCP surface is staff-only
and students cannot reach it, but the file-body path must not become a new way
around that.

Read tools are additive and safe under `MCP_MODE=read_only`; `restore` requires
`read_write`. Tool descriptions and `MCPServerInstructions.text` are updated
together, per the standing rule that the two stay in sync, and
`docs/mcp-authoring-roadmap.md` gains the three rows.

No UI in this cut. The data model is UI-ready — an instructor "History" panel on
the assignment edit page is a later slice with no schema change.

---

## 7. Consequences and edge cases

### 7.1 Deleting an assignment must not delete its history

`deleteAssignment` (`InstructorDashboardRoutes.swift:481`) hard-deletes the
submissions, the results, the zip, the notebook, and the `test_setups` row. If
`assignment_versions.test_setup_id` carried a foreign key, the history would go
with it — dying at exactly the moment recovery matters most.

So: `test_setup_id` is a plain string column with no FK, `assignment_id` is
nullable, and the FK is on `course_id` alone. Versions outlive a deleted setup.
This also leaves room for an "undelete an assignment" tool later with no schema
change; that is out of scope here but the shape should not foreclose it.

### 7.2 Clone copies content, not history

`cloneAssignment` and `copyCourse` copy live files into a **new** setup ID, so a
clone inherits no history for free — it just gets a `v1`. That is the intended
semantic: a new term starts with the current assignment and a clean slate.
`.chickadee` bundle export stays history-free; bundles are large enough already.

### 7.3 Notebook working copies

`NotebookWorkingCopyStore` holds an instructor's in-progress JupyterLite edits.
Restoring the starter notebook underneath an open working copy means their next
save silently reverts the restore. A restore invalidates the working copy, the
same way the existing instructor reset-notebook action does.

### 7.4 Retention and disk

Versions are never deleted by an instructor or an agent. They die with the
course: the `SubmissionRetentionService` purge and course delete drop the
version rows, then a sweep removes blobs with no remaining referencing row.
Instructor content is not FIPPA-sensitive the way submissions are, but a purged
course must not leave bytes on disk.

`testsetups/versions/` joins the admin disk-usage breakdown in `DiskUsage.swift`.

### 7.5 Concurrency

Two concurrent edits could compute the same `version_number`. The unique index
on `(test_setup_id, version_number)` plus one retry handles it — the same
discipline as `createAssignmentWithUniquePublicID`.

### 7.6 Manifest schema drift

An old snapshot's manifest can predate a `TestProperties` field. Decoding is
already lenient (`decodeIfPresent` throughout), so restoring an old manifest
re-encodes it to the current schema. Worth an explicit test: restore a manifest
missing `sections` / `testItems` and assert the round trip.

### 7.7 Cache invalidation is already handled

A restore changes the manifest and the zip, so the runner-side `TestSetupCache`
key (manifest + zip content hash) busts on its own, and generated-script
`spec_hash` headers travel inside the restored manifest. No action needed.

### 7.8 Personalization is unaffected

Per-student seeds live in `assignment_personalization_seeds` and are untouched
by a restore, so a restored suite regrades every student against the same seed
they had. That is the correct behaviour and needs no special handling.

### 7.9 Relationship to issue #421

[#421](https://github.com/jimwallace/chickadee/issues/421) (edit audit trail for
shared course staff) asks for actor + timestamp + action on every content
change, and explicitly scopes out diffing and restore. This design delivers that
half as a side effect — `actor_username`, `created_at`, `origin`, `summary` per
version — and adds the restore #421 deferred. #421 should be re-scoped to the
staff/enrollment events versioning does not cover, and to the recent-activity UI
panel.

---

## 8. Slice plan

1. **Storage core.** `assignment_versions` model plus migration, the
   content-addressed blob store, `AssignmentVersionStore.record` with dedupe and
   lazy baseline. Unit tests on hashing, dedupe, and numbering under
   concurrency.
2. **Capture.** Wire the web service-layer sites and the `finalizeMCPWrite`
   chokepoint; add the coverage guard test. No user-visible change yet — history
   starts accumulating.
3. **Read tools.** `list_assignment_versions`, `get_assignment_version`, plus
   instructions and roadmap updates.
4. **Restore.** `restore_assignment_version` with working-copy invalidation, the
   audit entry, and the regrade path.
5. **Lifecycle.** Creation-path `v1` seeding, purge and blob GC, disk-usage
   reporting.

Slices 1–2 are independently shippable and carry the recovery value on their own
(a snapshot that exists can always be restored by hand); 3–4 make it
self-serve.
