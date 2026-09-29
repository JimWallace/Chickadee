# Course terms and new-term cloning

**Status:** Slices 1 and 2 are built. Slices 3 to 6 are planned.

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
   but the author confirms it.
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
  (`CourseTermInput`, `CourseTermForm`). The form suggests the term that
  contains today in Waterloo time. A missing or invalid term redirects with
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

### Slice 3: Uniqueness per term, and code lookups

- A migration replaces `idx_courses_code_active` with a partial unique index
  on `(code, COALESCE(term_year, 0), COALESCE(term_season, ''))` for active
  courses. The `COALESCE` is necessary: SQL treats two NULLs as different, so
  without it two legacy courses with the same code and no term would both be
  allowed. The migration must work on SQLite and on Postgres.
- The duplicate checks in create, edit and import use the same key.
- Code lookups (see section 5) resolve a code to one course with this rule:
  1. Among active courses with this code, prefer the one the viewer is
     enrolled in.
  2. If more than one remains, take the newest term.
  3. An optional term qualifier selects one offering explicitly.
- MCP tools that take `courseCode` get an optional `term` argument (for
  example `"F26"` or `"Fall 2026"`). A **write** through an ambiguous code
  without a term is refused with a message that lists the offerings. A read
  uses the rule above. `list_courses` and `get_server_info` report the term.

### Slice 4: Clone for a new term (admin)

- Extract the body of `copyCourse` into `CourseCloneService.clone(...)`. The
  admin route becomes a thin caller.
- The clone form asks for the target **year and term** (default: the next
  term after the source), the **code** (default: the source code, allowed by
  slice 3) and the **name** (default: the source name).
- The clone copies: course sections, test setups (zip, notebook, draft
  solution notebook, shared support files), assignments (closed, not
  validated, due dates kept), content items and their attachments, enrollment
  mode, slip-day policy, and the course MCP authoring guide.
- The clone does **not** copy: enrollments, pre-enrollments, submissions,
  results, grade overrides, extensions, slip-day spends, achievement results,
  leaderboards, version history, and the LMS, BrightSpace and GitHub
  bindings. A new offering binds to its own LMS course.
- The clone does not archive the source. The instructor can still be
  exporting grades.
- Open question for slice 4: should due dates move forward by the length of
  one term, or stay as they are? The current copy keeps them.

### Slice 5: Clone for a new term (instructor)

- A "Clone for new term" action in the instructor area. The gate is
  per-course `instructor` of the source course.
- The system enrolls the cloning instructor as `instructor` in the new
  offering, in the same transaction.
- Optional: an MCP `clone_course` tool that uses the same service.

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
