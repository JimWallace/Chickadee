# Lecture notebooks

Status: **shipped** (shape A, confirmed by the maintainer 2026-11-25).
Progressive release of cells and an "updated since you opened it" notice are
follow-ups.

## The problem

HLTH 230 lectures are Jupyter notebooks. Today they are raw `.ipynb` files
linked from a course website, and a link to a raw notebook opens as JSON in
the browser. Students cannot run the instructor's example code alongside the
lecture without installing Jupyter.

Chickadee already has an in-browser notebook editor (`/testsetups/:id/notebook`)
with a xeus kernel per language, per-student working copies, and a staff save
path. But that editor exists only for assignments. Wrapping each lecture as a
`lab` assignment would:

- add a graded row to the gradebook and the grade CSV,
- push a (zero-point) grade to the LMS,
- require a validation pass before the lab can be published,
- show a Submit button and a test-results panel that mean nothing here.

A lecture notebook is wanted: ungraded course material whose notebook opens in
the same editor.

## Requirements

1. No Submit button, no grade, no LMS push, no validation gate to publish.
2. Each student gets their own working copy, seeded from the instructor's
   notebook, which persists across visits.
3. Staff edit the notebook in the editor and save it back.
4. MCP agents can create a lecture notebook and replace its notebook.
5. The item declares a language, as an assignment does, so the right xeus
   kernel boots. Nothing infers it (root `CLAUDE.md`, #1331).
6. It sits in a course section beside assignments, with the same ordering,
   publish toggle and section placement as other course content.

## The two shapes considered

### A. A content item backed by a test setup (chosen)

A lecture notebook is an `APICourseContentItem` of kind `.notebook` that owns a
**backing `APITestSetup`**. The setup holds:

- the notebook, at its `notebookPath`, as an assignment's starter does;
- a manifest with the declared `language`, no `testSuites`, and
  `submissionMode: notebook`.

There is **no `APIAssignment` row**. That is what keeps the item out of grading:
the gradebook, grade CSV, LMS push, deadlines, slip days, validation,
achievements and the dashboard's assignment counts all start from
`APIAssignment`, so none of them sees it.

The item gets one new nullable column, `lecture_test_setup_id`. A non-nil value
is what makes it a lecture notebook; the `kind` stays a display hint, as today.

The course page renders the item as a content row whose primary action is
**Open notebook**, linking to `/testsetups/<setupID>/notebook`. The notebook
page recognises a lecture setup (one referenced by a content item) and renders
a **lecture mode**:

| | Assignment | Lecture notebook |
|---|---|---|
| Submit, results panel, browser runner | yes | no (grading mode `none`) |
| Upload of an `.ipynb` | yes | no |
| Student working copy | `users/<id>/<setup>/…` | same |
| Reset to starter | yes | yes ("Reset to the instructor's version") |
| Staff "Save to assignment" | yes | "Save lecture notebook" |
| Visibility gate | assignment open state | content item published |
| Title | assignment title | content item title |
| Download | starter `.ipynb` | lecture `.ipynb` |
| Solution view | yes | no (404) |

Everything else (kernel boot, working-copy store, server drive, contents API,
staff authoring draft) is reused unchanged.

**Cost.** The notebook page has about forty `assignment != nil` branches that
mean "this is a real assignment, not a new-assignment draft". Lecture mode has
to be a third case beside those two, not a reuse of the draft case (a draft is
staff-only and its working copy *is* its stored notebook). The staff
dashboard's setup listing shows a setup with no assignment as an unpublished
draft, so it must skip lecture setups. Course clone, bundle export and course
purge must carry the setup with its item.

### B. A fourth assignment type, `lecture`

Add `AssignmentType.lecture`, an assignment with no suites and no grade. This
reuses the whole notebook page unchanged, but every place that enumerates
assignments for grading (gradebook, grade CSV, LMS push, deadlines, slip days,
validation gate, achievements, dashboard counts, the MCP assignment tools,
`check_assignment`) needs a new exclusion. That is the wider surface, and each
missed exclusion is a lecture showing up as a zero in a grade. **Rejected** for
that reason.

### C. A hosted `.ipynb` attachment with its own editor page

Store the notebook as a content-item attachment (`ContentFileRoutes`) and build
a second editor page at `/content/:itemID/notebook`. This duplicates the
notebook page, its working-copy store and its save path, which then drift.
**Rejected.**

## Decisions

### When the instructor edits the notebook mid-term

A student's working copy is their own work, so **it is never overwritten**. This
is the rule assignments already follow (`workingCopySeed`: "A student's copy
holds their own work, so it is never refreshed").

A student who opens the notebook for the first time after an edit gets the new
version, since their copy is seeded on first open.

A student who already has a copy keeps it. The editor's menu offers "Reset to
the instructor's version", which replaces their copy with the stored notebook.
That route already exists for assignments (`POST /testsetups/:id/reset-notebook`);
lecture mode allows it without the open-assignment gate, gated instead on the
item being published, and returns the student to the editor. The instructor can
say that a notebook changed in the item's "Updated" label.

An automatic "updated since you opened it" notice is a follow-up. Comparing
file times is not enough: a student who edits their copy after the
instructor's save has a newer copy that still holds the old cells. The notice
needs a record of which version seeded each copy.

Merging the instructor's new cells into a student's edited copy is not
attempted: cell identity across two edited notebooks is guesswork, and a wrong
merge destroys student work.

### Progressive release of cells during lecture

**Deferred to a follow-up.** It is useful (the instructor reveals one example at
a time) but it needs its own design: which cells are held back, how a student
copy seeded before a release gets the released cells, and how the held cells
stay off the contents API. The v1 shape does not block it: a later version can
add a per-cell tag (for example `chickadee:release-after`) to the stored
notebook and filter at seeding time.

### Language

The lecture setup's manifest declares the language. Creating a lecture notebook
requires it, through the web form's language dropdown or the MCP `language`
argument. Python, R, Lua and Octave are accepted (the four languages with an
editor kernel); an upload-only language is refused with its reason from
`LanguageDescriptor`, because a lecture notebook has no upload path. There is
no default.

### Personalization

Not supported. A lecture notebook is the same for every student: it has no
per-student inputs, so do not put `{{name}}` placeholders in one.

### Datasets and support files

A lecture setup can carry support files the same way an assignment does (the
working copy's support-file symlinks are per setup). v1 does not add a UI for
them; the MCP `attach_dataset` path is a follow-up if lectures need data files.

## Surfaces

**Web, staff.** Each section's "+ Add" menu has a "Lecture notebook" entry. Its
panel posts to `POST /instructor/content-items/lecture` with a title, a
language (no default), an optional `.ipynb` (a blank notebook in the language
when none is given), a description and a visibility (hidden by default, so a
lecture can be prepared before class). The row's staff actions add **Edit
notebook** (the editing view, `?edit=1`). The language is changed through MCP;
the web edit form has no language field yet.

**Web, students.** A published lecture notebook shows as a content row with an
**Open notebook** button. An unpublished one is not listed, and its notebook
page and source endpoint answer 404 to a student.

**MCP.** `create_content_item` and `update_content_item` take an optional
`lectureNotebook: { language, notebook }` argument (`notebook` is the `.ipynb`
JSON object, as `update_notebook` takes it). On update it is refused for an
item that is not already a lecture notebook. `list_content_items` and the
create and update outputs report `lectureNotebook: { language, notebookPath,
editPath }`. `get_lecture_notebook` returns the stored notebook. No tool prose
names a language; the allowed ones are those with an editor kernel, which
`get_server_info` reports.

**Course clone, bundles, purge.** A course clone copies the setup with the
item. A course bundle carries it as `lectureSetupBundleID`, a reference to the
bundled test setup. A course purge deletes the setup with the course's other
setups, and the foreign key clears the column. Deleting the item deletes its
setup and the setup's files; students' working copies stay on disk, as they do
when an assignment is deleted.

**Submissions.** `requireOpenStudentAssignment` refuses the `.submission`
gate for a lecture setup, so every student door that hands work in stops
there. It reads the item only when the setup has no assignment row, so an
assignment's submission pays no extra statement.

**Not touched.** No path in `scripts/contract-paths.txt`: no kernel, editor,
runner wasm or `RunnerCore` change. The browser runner does not boot in lecture
mode, so no grading cell changes either.

## Shared objects

| Object | Written by | Read by | Rule |
|---|---|---|---|
| `course_content_items.lecture_test_setup_id` | lecture create / delete | course page, notebook page, staff setup listing, clone, bundle, purge | A setup referenced here has no `APIAssignment` row and never gets one. |
| The lecture `APITestSetup` | lecture create, staff save, MCP update | notebook page, working-copy store, contents API | Its manifest has no suites; nothing enqueues a submission against it. |
| `jupyterlite/files/users/<id>/<setupID>/` | the student's editor | the student's editor | Never overwritten by a staff save. |

## Done

A published lecture notebook on the course page opens runnable in the editor for
an enrolled student, with no Submit button, and a staff save changes what a new
student is seeded with.
