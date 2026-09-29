# Course terms and new-term cloning

**Status:** Slices 1 to 5 are built. Slice 6 (documentation) is planned.

This document replaces the plan in
[clone-course-for-new-term.md](clone-course-for-new-term.md) (issue #420). That
plan did not have a term on the course. This plan adds one, and the clone
workflow uses it.

---

## 1. Goal

Each course offering has a **year** and a **term**. The term identifies one
offering of a course, for example "CS135, Fall 2026".

- The year is a four-digit number (1000 to 9999).
- The term is one of **Winter**, **Spring** or **Fall**. These are the three
  terms of the University of Waterloo calendar. Winter starts in January,
  Spring in May and Fall in September.

An instructor can clone a course from a previous term into a new term. The
clone copies the course content (assignments, test setups, sections, content
items and course settings). The clone does not copy people, submissions or
results.

---

## 2. Decisions (maintainer, 2026-09-29)

| Question | Decision |
|---|---|
| Course-code uniqueness | **Unique per term.** Two active offerings can have the same code if their terms are different. The unique key becomes (code, year, term) for active courses. |
| Is the term required? | **Required for new courses.** Create, clone and bundle import all require a term. An existing course keeps no term until an admin sets one. Chickadee does not guess a term from a date. |
| Who can clone? | **Admins and instructors.** A per-course instructor of the source course can clone it. The system enrolls that instructor as `instructor` in the new offering. |

Two rules follow from these decisions:

1. **Nothing infers a term.** A course with no term means "no term recorded".
   This is the same rule as the assignment-language declaration
   ([language-declaration.md](language-declaration.md)). A form can *suggest* a
   term (the next term after the source, or the term that contains today),
   but the author confirms it. (The create form does not suggest one; see
  slice 2.)
2. **A code alone can name more than one active course.** Every place that
   finds a course by its code must decide which offering it means. Section 5
   lists these places.

---

## 3. Data model (slice 1, built)

- `Core/AcademicTerm.swift`: `TermSeason` (`winter`, `spring`, `fall`, in
  calendar order) and `AcademicTerm` (year + season). `AcademicTerm` is
  `Comparable` in calendar order and has `next`, `displayName` ("Fall 2026")
  and `containing(_:)` (the term that contains a date, for form defaults
  only).
- Two nullable columns on `courses`: `term_year` (int) and `term_season`
  (string, a `TermSeason` raw value). Migration: `AddCourseTerm`.
- `APICourse.term` is the typed accessor. It returns nil unless both columns
  are present and valid. Setting nil clears both columns. Do not read the raw
  columns directly.

The columns are nullable because existing courses have no term. Slice 2 makes
the term required at every door that creates a course.

---

## 4. Slices

Each slice is one pull request. Each slice ships independently and keeps the
build green.

### Slice 1: Foundation (built)

The Core type, the migration, the model accessor, and tests
(`AcademicTermTests`, `CourseTermPersistenceTests`). No behaviour changes.

### Slice 2: Declare the term at every door (built)

- Admin **create** form: year input and term select, both required
  (`CourseTermInput`, `CourseTermForm`). The form starts empty and suggests
  nothing: that fits the rule that nothing guesses a term, and a default
  taken from today's date would change the visual-regression baseline of
  the page every term. A missing or invalid term redirects with
  `course_term_required`; a duplicate active code redirects with
  `code_taken`.
- Admin **edit** form: set or change the term. This is how an admin gives an
  existing course its term. A post without the term fields leaves the term
  as it is. A post with an invalid pair changes nothing. The page now shows
  the `code_taken` error that the route always sent.
- **Bundle export** writes `termYear` and `termSeason` into `BundledCourse`
  (optional, so an old bundle still decodes; resolved through
  `bundledCourseTerm`). **Bundle import** records the bundle term.
- **Deviation from the first plan:** an old bundle, which has no term,
  imports with **no term**, and the result page shows a warning with a link
  to the course page. The first plan put a term field on the import form,
  but the import form is a hidden file input that submits on file choice.
  The import records exactly what its source declared, and nothing is
  guessed. The existing import tests also post term-less bundles.
- The import conflict check now asks for an ACTIVE course with the code. The
  old first-match query could see an archived duplicate, pass, and then fail
  on the unique index.
- The term shows where a person picks or identifies a course. The long form
  is always "CS135 Fall 2026 — Name"; the course tab uses "CS135 F26". The
  places: the course tabs and the instructor switcher, the admin courses
  table (a sortable Term column), the admin course page, the import result,
  the retention page, the LTI bind picker, and the enrollment and account
  pages. Course lists sort newest term first, then courses with no term,
  then by code (`courseListPrecedes`). With no terms recorded, this is the
  old code order.

### Slice 3: Uniqueness per term, and code lookups (built)

- Migration `ScopeCourseCodeIndexToTerm` replaces `idx_courses_code_active`
  with `idx_courses_code_term_active`, a partial unique index on
  `(code, COALESCE(term_year, 0), COALESCE(term_season, ''))` for active
  courses. The `COALESCE` is necessary: SQL treats two NULLs as different,
  so without it two courses with the same code and no term would both be
  allowed. "No term" is therefore one term, and the old rule holds for every
  course that has not declared one.
- `activeCourseCodeIsTaken(_:term:excluding:on:)` applies the same rule, so
  create, edit and import report a duplicate instead of failing on the
  index. Edit no longer refuses a code that only an archived course uses.
- **The URL key.** `APICourse.urlKey` is the code for a course with no term,
  and "CS135-F26" for a course with one (`AcademicTerm.shortLabel`, parsed
  back by `AcademicTerm(shortLabel:)`, years 2000 to 2099). Every link
  Chickadee writes into a `/:courseCode/...` path uses the key: the vanity
  links (instructor list, student index, LTI launch) and the
  `/:courseCode/students/...` family. `CourseContext.pathKey` carries it into
  the dashboards. A course with no term keeps its old URLs.
- **Web resolution** (`findActiveCourse(byKey:viewer:on:)`): an exact code
  match first, so a legacy code such as "CS136-W26" still resolves; else a
  key names code and term. With several matches, the viewer's enrolled
  course wins, then the newest term. So an old bookmark "/CS135/lab1"
  opens the offering the student is in.
- **MCP resolution** (`resolveMCPCourse`): `courseCode` takes a code or a
  key. With several matches, an active course beats an archived one, and a
  course the acting account is enrolled in beats one it is not. If several
  still remain, a read takes the newest term and a **write is refused** with
  the keys to choose from. `list_courses` returns each course's `term` and
  `key`. The course guidance resources and the initialize guidance use the
  key, so two offerings do not share a URI.
- The enrollment lookup that MCP resolution needs lives in `ToolContext`
  (`subjectEnrollments(among:)`), the one MCP file allowed to query identity
  models (`MCPStudentDataWallTests`).

### Slice 4: Clone for a new term (admin) (built)

- `CourseCloneService.clone(source:target:directories:contentFilesDirectory:on:)`
  is the one clone path. For each assignment it calls
  `AssignmentAuthoringService.cloneAssignment`, the path of the MCP
  `clone_assignment` tool. So the setup zip, starter notebook, reference
  solution, shared support files and first version snapshot copy the same
  way everywhere. The route runs the clone in one transaction and records a
  `course.cloned` audit entry.
- The admin course page has a **Clone for a new term** section
  (`#clone-course`). Its fields are the code (default: the source code), the
  name (default: the source name), and the year and term (default: the term
  after the source's term, from `AcademicTerm.next`; no default when the
  source has no term). It posts to `POST /admin/courses/:courseID/clone`. The
  copy icon in the admin courses table now links to this section.
- The older one-click `POST /admin/courses/:courseID/copy` stays, as a thin
  caller of the same service. It keeps its `-COPY` code and "(Copy)" name.
  It now also keeps the source term, so the copy is a sandbox in the same
  term.
- **Copied:** course sections; every assignment (setup, notebook, reference
  solution, support files, section, order, secret-reveal flag, passing
  threshold, LMS sync exclusion); content items and their attachment files;
  the enrollment mode, the slip-day policy, and the course MCP authoring
  guide.
- **Not copied:** enrollments, pre-enrollments, submissions, results, grade
  overrides, extensions, slip-day spends, achievement results, version
  history, and the LMS, BrightSpace and GitHub bindings (including the grade
  item and line item of each assignment). A new offering binds to its own
  LMS course.
- **Dates (the open question, now decided):** every copied assignment starts
  closed and unvalidated, with **no due date and no start date**, and its
  solution reveal is set back to hidden. The source dates belong to the
  source term. A stale date is not harmless: with no date, or a date in the
  past, an "after due" solution policy shows the answer key as soon as the
  assignment opens. The instructor sets new dates, and turns the reveal on
  again, for the new term. A shift of the dates by one term length was
  rejected: term lengths and weekdays are different, so a shifted date is a
  guess.
- The clone does not archive the source. The instructor can still be
  exporting grades.

### Slice 5: Clone for a new term (instructor) (built)

- The instructor area has a **New term** tab (`GET /instructor/new-term`,
  `instructor-new-term.leaf`). It clones the active course with the same
  form as the admin clone: code, name, year and term, with the term after
  the active course's term as the default.
- `POST /instructor/new-term` requires a per-course `instructor` role in the
  source course (`requireCourseRole`; admins pass). It is a read of the
  source, so the archived-course write block does not apply. A TA sees the
  tab with a note, and the POST refuses a TA with 403.
- Course creation is otherwise admin-only. An instructor can create a course
  only as a clone of a course they teach. In the same transaction as the
  clone, the cloning instructor is enrolled as `instructor` in the new
  course, and nobody else is enrolled. Other staff and the students join
  the new term again.
- After the clone, the new course becomes the active course, and the tab
  shows a message that tells the instructor to set dates before opening
  assignments.
- The handlers are on `CourseAdminRoutes` (`CourseAdminRoutes+NewTerm.swift`),
  with the other instructor course-lifecycle routes.
- Not built: an MCP `clone_course` tool. The service would support one, but
  course creation through an agent is a separate decision.

### Slice 6: Documentation

Update `CLAUDE.md`, `docs/multi-course-roles.md` (the "no term/semester"
statement), `docs/slip-days.md`, `docs/admin-mcp.md`, and mark
`clone-course-for-new-term.md` as superseded.

---

## 5. Places that find a course by its code

After slice 3, a code can name more than one active course. These places must
use the lookup rule in slice 3:

| Place | File |
|---|---|
| `findActiveCourse(byCode:)` | `Routes/Web/CourseLookupHelpers.swift` |
| Vanity URLs `/:courseCode/:assignmentSlug` (and `/notebook`, `/submit`, `/history`, `/leaderboard`) | `Routes/Web/VanityURLRoutes.swift` |
| Staff student paths `/:courseCode/students/...` | `Routes/Web/StudentCoursePaths.swift`, `StudentCourseRoutes+History.swift` |
| MCP `resolveCourseID` / `resolveCourseIDForWrite` (these do not filter archived courses today) | `MCP/Tools/CourseSectionTools.swift` |
| MCP `list_assignments`, `clone_assignment` | `MCP/Tools/ListAssignmentsTool.swift`, `CloneAssignmentTool.swift` |
| MCP resource `chickadee://course/<code>/authoring-guidance` | `MCP/Resources/MCPResourceProvider.swift` |
| Admin MCP `get_instructor_card_series` | `MCP/Admin/Tools/GetInstructorCardSeriesTool.swift` |
| Bundle import conflict check (also a latent bug: it can see an archived duplicate first) | `Routes/Web/CourseBundleRoutes+Import.swift` |

---

## 6. Non-goals

- A separate `Term` table. A term is two columns on the course. A table would
  add an admin page and a join for no present need.
- A term calendar with start and end dates. Archiving stays the "end of term"
  signal for the retention clock.
- Moving existing courses to a term automatically.
