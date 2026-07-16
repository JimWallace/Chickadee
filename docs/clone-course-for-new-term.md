# Clone course for new term (issue #420)  -  plan

**Status:** Planning. This doc re-scopes #420 against the *current* codebase, which
has moved on since the issue was filed (2026-04-25). Most of the gaps the issue
lists are already closed; what remains is mostly UX plus a few real copy gaps and
the test net.

---

## 1. TL;DR  -  the issue is largely stale

#420 was written when the `.chickadee` bundle was the only duplication path and it
predated sections and pattern families. Since then, a same-deployment
`copyCourse` landed and the bundle gained section support. Re-checking each gap
the issue calls out:

| #420 stated gap | Current reality | Where |
|---|---|---|
| "Two-step (no single clone)" | **Partly closed.** `POST /admin/courses/:courseID/copy` (`copyCourse`) is a one-click same-deployment clone, with a button on `admin.leaf`. It's just not framed as "clone for new term" and the naming is `...-COPY`, not term-aware. | `AdminRoutes+Courses.swift` `copyCourse` (~L117-226); `admin.leaf` |
| "Sections not exported" | **Closed.** *Two* section concepts exist (see section 3). Course sections (`APICourseSection`) are copied with an old->new ID remap by `copyCourse` and carried by the bundle as `BundledSection`. Test-suite sections live inside `TestProperties.sections` in the per-setup `manifest`, which is copied/exported verbatim. | `copyCourse` section loop; `CourseBundleManifest.sections` (nullable, back-compat); `TestProperties.sections` |
| "Pattern families not exported" | **Closed.** Families (and notebook checks) live in `TestProperties.testItems` inside `manifest`, copied verbatim by both `copyCourse` and the bundle. | `Core/TestProperties.swift` (`testItems`/`patternFamilies`/`notebookChecks`); manifest carried verbatim |
| "Student data is included" | **Already correct for `copyCourse`.** `copyCourse` copies **no** enrollments / submissions / results  -  exactly the new-term semantics. (The *bundle* still includes student data by design, for same-server backup.) | `copyCourse` omits those queries |
| "Validation reset on import" | **Confirmed desirable.** Both `copyCourse` and bundle import set `validationStatus: nil` and `visibility: .closed`, so a cloned course is unvalidated + closed until the instructor re-validates. | `copyCourse` L204-219; import L433 |

So the conceptual heavy lifting is done. `copyCourse` is, in effect, the
"clone for new term" engine already  -  it just isn't surfaced as one, isn't
term-aware, isn't available to instructors, and has a couple of real copy gaps
and **no tests**.

---

## 2. What `copyCourse` does today (the engine)

`copyCourse` (`AdminRoutes+Courses.swift`), in one transaction:

1. Creates a new course `code = uniqueCopyCode(base)` (`CS136-COPY`, `-COPY-2`, ...),
   `name = "<source> (Copy)"`.
2. Copies `APICourseSection` rows, building an old->new UUID map.
3. Copies each `APITestSetup`: new `setup_<8>` id, **byte-for-byte zip copy**,
   notebook copy (via the stored `notebookPath`), and `manifest` copied verbatim
   (so families, checks, test-suite sections, global vars/expressions, datasets,
   achievements all come along).
4. Copies each `APIAssignment`: remapped `testSetupID` + `sectionID`, fresh unique
   slug, `visibility: .closed`, `validationStatus: nil`.
5. Omits enrollments, submissions, results.

The MCP `clone_assignment` tool and `copyCourse` both delegate per-assignment
copying to `AssignmentAuthoringService.cloneAssignment`, so the two can't drift.

---

## 3. Two "section" concepts (don't conflate them)

- **Course sections**  -  `APICourseSection` (DB table). Group *assignments* within a
  course ("Labs", "Exams"). Have `defaultGradingMode`, `sortOrder`. Copied by
  `copyCourse` (ID-remapped) and exported as `BundledSection`.
- **Test-suite sections**  -  `TestProperties.sections` (inside the per-setup
  `manifest` JSON). Group *tests* within one assignment and carry section
  variables/expressions. Travel automatically wherever `manifest` travels.

Both already survive a same-deployment clone.

---

## 4. The remaining work (the real gaps)

### A. Surface a real "Clone for new term" action (the headline)
- Extract the `copyCourse` body into a reusable `CourseCloneService.clone(source:newCode:newName:on:)`
  returning the new course id. (Keeps `copyCourse` as a thin caller; lets the
  instructor route and any future MCP tool reuse one path  -  same discipline as
  `AssignmentAuthoringService.cloneAssignment`.)
- Replace the bare `...-COPY` naming with a **modal**: new course **code** + **name**,
  pre-filled with a term-aware suggestion (see section 6 Q2). Redirect to the new
  course's edit page on success.
- Keep the current no-arg `copyCourse` behavior available, or fold it into the
  modal default  -  the modal is the new front door.

### B. Make it instructor-reachable (gated per #417)
- Add the clone action to the instructor course view, gated to a **per-course
  instructor** of the source course (`requireCourseWriteAccess`/`requireCourseInstructor`,
  the Slice A/B helpers). Course *creation* stays admin-only today (#417 decision),
  so the cloned course's ownership/enrollment of the cloning instructor needs a
  decision (see section 6 Q5)  -  simplest: the cloning instructor is auto-enrolled as
  instructor in the new course.

### C. Close the genuine copy gaps
- **Draft solution notebook.** `copyCourse` copies the assignment's `notebookPath`
  but not the separate *draft solution* notebook some setups carry
  (`testsetups/notebooks/<id>/solution.ipynb`, written by `createSolutionFromAssignment`).
  Audit and copy it alongside the assignment notebook. (The committed `solution.py`
  and support files live **inside the zip**, which is copied byte-for-byte, so
  those already survive  -  confirm with a test rather than new copy code.)
- **Notebook round-trip** for the bundle path: the issue flags this as untested;
  add an explicit assertion (see D).

### D. Tests (currently absent for `copyCourse`)
The research found **no `copyCourse` tests**. Add round-trip coverage:
- Clone a course with: >=2 course sections, an assignment in each, a pattern
  family, a notebook check, test-suite sections w/ variables, an achievement, a
  due date, plus enrollments + submissions on the source.
- Assert on the clone: sections + assignments + setups duplicated with **new**
  ids; `manifest` (families/checks/sections/vars/achievements) byte-identical;
  assignment `sectionID`/`testSetupID` correctly remapped; slug unique; `visibility
  == .closed`; `validationStatus == nil`; **zero** enrollments/submissions/results;
  source course untouched.
- Bundle round-trip: export->import preserves `BundledSection` and manifest-carried
  families; an **old** (pre-section) bundle still imports (nullable `sections`).
- (After B) instructor-initiated clone authz: per-course instructor of the source
  may clone; a student/non-member may not.

### E. (Optional, lower priority) Bundle "clone mode" for cross-deployment
Same-deployment cloning is fully covered by `CourseCloneService`. The only thing
the bundle path uniquely offers is **cross-deployment** transfer, and there it
still carries student data. If/when cross-deployment new-term setup is needed,
add an `instructor-only` export mode that strips `users`/`enrolledUserBundleIDs`/
`submissions`/`results` from the manifest before zipping. Defer until asked  -  the
in-process clone (A) covers the stated workflow without touching the upload UI.

---

## 5. Phasing

1. **`CourseCloneService` extraction + draft-solution-notebook fix + tests (D for `copyCourse`).**
   Pure refactor + one real fix, fully testable, no UX change. Lands first.
2. **"Clone for new term" modal on the admin course page** (code/name + term-aware
   suggest, redirect). Wraps the service.
3. **Instructor-facing clone** (gated per #417; auto-enroll the cloning instructor).
4. **Bundle round-trip test + back-compat assertion** (and, only if needed,
   the optional instructor-only export mode E).

Each phase ships independently; phase 1 is the foundation and the highest-value
risk reduction (it's the engine for everything else and currently untested).

---

## 6. Open questions / decisions

1. **Scope toggles.** Default to "clone everything except people, submissions, and
   results." Add per-tier opt-outs (e.g. drop `student`-tier tests) only if real
   users ask. (Issue Q1.)
2. **Term-aware code suggestion.** Infer the next term from the source code where a
   recognizable token exists (`...W26` -> `...F26` -> `...S26`/`...W27`); otherwise fall back
   to the current `-COPY` scheme. Keep it a *suggestion* the instructor can
   overwrite  -  codes must stay unique per the `APICourse.code` constraint. (Issue Q2.)
3. **Auto-archive the source?** No  -  the instructor may still be exporting grades.
   Keep archival a separate manual action. (Issue Q3.)
4. **Notebook starter content round-trip.** Covered by the test in section 4D rather than
   assumed. (Issue Q4.)
5. **New-course ownership for an instructor-initiated clone.** Course creation is
   admin-only today (#417). Simplest resolution: an instructor cloning a course
   they instruct is auto-enrolled as `instructor` in the clone; revisit if a
   "instructors may create courses" policy lands later.

---

## 7. Non-goals

- Cross-deployment new-term setup (the bundle path) beyond the optional section 4E mode.
- Cloning enrollments, submissions, results, or validation history (a new term
  starts empty by definition).
- Any change to the grading pipeline, runner protocol, or Core grading types  - 
  this is purely a course-duplication/UX concern.

---

## 8. Files likely touched

- `Sources/APIServer/Services/CourseCloneService.swift`  -  **new**, extracted engine.
- `Sources/APIServer/Routes/Web/AdminRoutes+Courses.swift`  -  `copyCourse` becomes a
  thin caller; add the modal-backed clone endpoint.
- Instructor course view route + `Resources/Views/...`  -  clone button + modal.
- `Resources/Views/admin-course.leaf`  -  clone button + modal.
- `Sources/APIServer/Services/AssignmentAuthoringService.swift`  -  draft-solution
  notebook copy (if not already handled there).
- `Tests/APITests/`  -  new `CourseCloneServiceTests` / bundle round-trip assertions.
- `Sources/Core/CourseBundleManifest.swift`  -  only if the optional section 4E export mode
  is built.
