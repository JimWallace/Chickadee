# Multi-course roles & university-scale organization

**Status:** Active. Theme 1 (per-course roles) is being implemented in phases;
**Phases 1–3 have landed** — Core `CourseRole` + the `course_enrollments.role`
column + the behaviour-preserving backfill (Phase 1), the read-path wiring that
carries the per-course role into the nav (Phase 2), and the role-aware
authorization chokepoint `requireCourseRole(atLeast:)` (Phase 3). Companion to
the earlier fix that scoped the home dashboard and the "Instructor" nav tab to
course enrollment (PR #972) — that fix was the first concrete step toward the
model described here.

The owner's design decisions are recorded in [§6](#6-decisions) and are
settled; they shape Phases 4–5 (the behaviour-changing ones). Theme 2
(university-scale organization) remains design-only.

---

## 1. Motivation

Chickadee already runs many courses in one deployment, but its **identity
model is single-course-shaped** in two ways:

1. **Role is global.** `APIUser.role` is one of
   `student` / `instructor` / `admin` / `mcp`, applied across the *whole
   deployment*. A person therefore cannot be an instructor in one course and a
   student in another — a common real situation (a grad student who TAs CS136
   and takes CS440; an instructor auditing a colleague's offering; a
   sessional teaching one course this term and none the next).

2. **There is no organizational layer above courses.** The hierarchy is flat:
   deployment → courses → assignments. There is no term/semester, no
   department/faculty, and `admin` is all-or-nothing (the entire deployment).

The recent fix leaned on a principle already stated in
`Sources/APIServer/Helpers/CourseAccessHelpers.swift`:

> Everyone — instructors included — must be enrolled in the specific course
> that owns the resource. … admins see — and their agents may act on — exactly
> what they are enrolled in.

i.e. **enrollment scopes course participation; the global role is a deployment
capability.** But because role is global, the nav and permission story is
still "instructor-ish *everywhere* or *nowhere*." The two bugs that fix
addressed were the last places where the global `isInstructor`
(admin-implies-instructor) leaked past enrollment scoping.

The natural next step is to make participation *role*-scoped to a course, the
same way it is already *visibility*-scoped to a course.

---

## 2. Current model (what exists today)

| Concern | Where | Shape |
|---|---|---|
| Global role | `Sources/APIServer/Models/APIUser.swift` — `UserRole` enum, `role` field, `isInstructor`/`isAdmin` | One string column on the user. `isInstructor == (role == .instructor \|\| role == .admin)`. |
| Enrollment | `Sources/APIServer/Models/APICourseEnrollment.swift` | Join row `(user_id, course_id)`. As of Phase 1 it also carries a per-course `role` (`CourseRole`), seeded behaviour-preservingly from the global role and **not yet read** — the global role still governs capability until Phases 2–4 wire this in. |
| Access policy | `Sources/APIServer/Helpers/CourseAccessHelpers.swift` — `requireCourseEnrollment`, `userIsEnrolled`, `enrolledCourses` | The single chokepoint both the web routes and MCP tools resolve course access through. Admin is the one bypass. |
| Active-course resolution | `APIUser.swift` — `resolveActiveCourse`, `CourseContext`, `ResolvedCourseState` | Picks the active course from session/DB, auto-enrolls `.auto` courses, returns the enrolled set. |
| View context | `APIUser.swift` — `CurrentUserContext` | Carries `isAdmin`, `isInstructor`, `activeCourse`, `enrolledCourses` into Leaf. The nav (`Resources/Views/base.leaf`) reads these. |
| Route gating | `Sources/APIServer/Middleware/RoleMiddleware.swift`; groups in `Sources/APIServer/routes.swift` (`.authenticated` / `.instructor` / `.admin`) | Coarse, **global**-role gates at the group level. |
| Agent scope | `Sources/APIServer/MCP/Tools/ToolContext.swift` — `authorizeCourseAccess` | Enrollment-scoped, so agent scope ⊆ human scope. |

The good news: visibility is *already* funnelled through one resolver
(`enrolledCourses` / `resolveActiveCourse`) and access through one helper
(`CourseAccessHelpers`). Those are the seams Theme 1 threads a role through —
there is no scattered role logic to chase down.

---

## 3. Theme 1 — Per-course roles (the foundation)

### Goal

A user's capability is determined by their role **in a given course**. The
global `APIUser.role` shrinks to the one genuinely deployment-wide capability:
`admin` (super-user). "Instructor in CS136, student in CS440" becomes
representable and creatable.

### 3.1 Data model

- Add `role` to `course_enrollments` — a new `CourseRole` enum in `Core/`
  (`Codable`, `Sendable`). Per [§6](#6-decisions) it ships with two rungs,
  `student` and `instructor`; `ta` is deferred (the type is string-backed, so
  adding it later needs no schema change). Default `student`. **(Implemented —
  `Sources/Core/CourseRole.swift`.)**
- Reinterpret `APIUser.role`:
  - `admin` stays a **deployment** super-user (manages courses, users,
    runners; bypasses course checks).
  - For everyone else the global role stops carrying course capability —
    capability comes from the enrollment row. Per [§6](#6-decisions) course
    creation stays **admin-only**, so the global `instructor` role collapses
    entirely into "instructor on some enrollment" — there is no surviving
    deployment-level `instructor`. (That collapse is Phase 5 work; the global
    role is untouched through Phases 1–4.)

### 3.2 Migration / backfill (behavior-preserving) — **implemented**

- `AddCourseEnrollmentRole` adds `role` as a **nullable** column and backfills
  it. It deliberately does not add a DB-level NOT NULL/default: Fluent +
  SQLite can't add a NOT NULL column to an existing table post-hoc, so — like
  `AddUrlTokenToUsers` — the column stays nullable and the "every row has a
  role" invariant is held by the model-side `init` default plus the typed
  accessor (which falls back to `.student` for a missing value).
- **Backfill rule:** for each existing enrollment, set
  `role = (user.isInstructor ? .instructor : .student)`. A current global
  instructor therefore becomes instructor in *every course they're already
  enrolled in*, and students stay students — so **day-one behavior is
  identical**. Admins keep their global bypass.
- This is the key property: Phases 1–3 below can ship with *no observable
  change*, because the per-course role is seeded to reproduce the global one.
  The behavior change only arrives when someone *authors* a mixed role
  (Phase 4).

### 3.3 Read path (visibility / nav) — **implemented**

- `CourseContext` carries `role: CourseRole`, populated by a new
  `enrolledCoursesWithRoles` resolver (the enrollment row is already loaded —
  no extra query). `enrolledCourses` is now defined in terms of it, so the
  role-free MCP visibility set can't drift from the web one.
- `CurrentUserContext` exposes `isInstructorInActiveCourse`, and `base.leaf`
  keys the Instructor tab off *that* instead of the global `isInstructor`. It
  is `true` when the active course's role is `.instructor` **or** (a
  transitional fallback) the user is a global instructor/admin — so today's
  behaviour is identical (every enrollment's role mirrors the global role),
  while a future global-student-who-is-instructor-here already lights up the
  tab. The fallback is dropped in Phase 5 when the global role shrinks.
  Switching the course tab then switches the same account between instructor
  and student views — the desired UX for a TA-who-is-also-a-student.

### 3.4 Auth path (permissions) — **chokepoint implemented**

- `CourseAccessHelpers` is the chokepoint: `requireCourseRole(caller:courseID:
  atLeast: CourseRole, db:)` is in, and `requireCourseEnrollment` is now its
  `.student` case (a one-call delegation, so every existing caller is
  unchanged). Authority is **purely per-course** — admin bypass only, no global
  instructor bypass — and `CourseRole` is `Comparable`, so `role >= .instructor`
  reads naturally. `courseRole(of:inCourse:db:)` is the single role read behind
  it. **(Done.)**
- *Deferred to Phase 4* (the tightening): an audit showed the web authoring
  surfaces are gated by `RoleMiddleware(.instructor)` — a **global**-role group
  guard in `routes.swift` — not by a per-course `requireCourseEnrollment`, which
  is used on the student/content endpoints. So flipping authoring to
  `atLeast: .instructor`, relaxing `RoleMiddleware` to a coarse "instructor in
  *some* course, or admin" gate, and making `ToolContext.authorizeCourseAccess`
  role-aware are sequenced with Phase 4, when per-course instructor enrollments
  become *authorable* — that is when these checks first change a real outcome
  (a global student authoring in a course they instruct) and become testable
  end-to-end. Until then `requireCourseRole(atLeast: .instructor)` is exercised
  only by unit tests.
- Submit / view endpoints stay at "enrolled" (`atLeast: .student`).

### 3.5 UI touchpoints

- **Enrollment management** (`CourseAdminRoutes+Enrollment.swift`, the CSV
  bulk-enroll + roster): a per-row role, defaulting to `student`; an
  instructor enrolls a TA / co-instructor by choosing `instructor`. This is
  the screen where mixed roles become *creatable*.
- **Roster + account/"my courses"** views show the role per course.
- `EnrollUsernamesResult` and the pre-enrollment (`APIPreEnrollment`) flow
  carry the intended role so a not-yet-registered TA lands with the right
  role on first login.

### 3.6 Suggested phasing

1. **Core + schema. ✓ Done.** `CourseRole`, the `AddCourseEnrollmentRole`
   migration, the backfill. No reads of the new column yet → zero behavior
   change.
2. **Read path. ✓ Done.** `CourseContext.role`, nav keyed off
   `isInstructorInActiveCourse`. Still identical behavior (the role mirrors the
   global role, plus a transitional global-role fallback in the nav predicate).
3. **Auth path. ✓ Done (chokepoint).** `requireCourseRole(atLeast:)` +
   `CourseRole` ordering; `requireCourseEnrollment` is its `.student` case.
   Behaviour-neutral (only `.student` is called in production). Flipping
   authoring handlers / `RoleMiddleware` / MCP to `.instructor` is folded into
   Phase 4 — see §3.4.
4. **Authoring UI.** Per-course role on enroll/roster. **This is where
   "instructor here, student there" goes live.**
5. **Shrink the global role.** Collapse `APIUser.role` to `admin`-only (per
   [§6](#6-decisions) the global `instructor` goes away entirely). Revisit SSO
   role mapping here — per [§6](#6-decisions) `SSO_INSTRUCTOR_USERS` keeps its
   current global-role behavior until this phase. Longest tail; can lag well
   behind 1–4.

---

## 4. Theme 2 — University-scale organization (follow-on, lower resolution)

This is sketched, not specified — it should get its own doc once Theme 1
lands.

- **Terms / semesters.** A `Term` entity ("Fall 2026"); a course belongs to a
  term. Re-offering CS136 each term becomes "a new course in a new term,"
  not today's archive-and-recreate. Course-code uniqueness becomes
  *per-term*; the archive-based retention clock
  (`SubmissionRetentionService`) re-anchors on term rollover.
- **Departments / faculties.** An org-unit grouping courses; dashboards and
  admin organize by department instead of one flat list.
- **Scoped administration.** Today `admin` is deployment-wide. University
  scale wants a **department admin** who manages only their department's
  courses. That is the *same pattern as per-course roles, one level up*:
  an admin capability attached to an org-unit instead of the deployment.
  Building Theme 1 first means the "capability scoped to an affiliation"
  machinery (role-on-join-row, role-aware chokepoint helper) already exists
  to reuse here.

**Why Theme 1 first:** per-course roles establish the affiliation-scoped
capability pattern and make the access helper role-aware. Department-scoped
admin is structurally identical at the org-unit level, so it slots into that
machinery cleanly rather than inventing a parallel one.

---

## 5. Non-goals (for now)

- Multi-tenant / cross-deployment isolation (several universities in one
  instance).
- Arbitrary custom permissions beyond the role ladder.
- Changing the grading pipeline, runner protocol, or any Core grading type —
  this is purely an identity/organization concern.

---

## 6. Decisions

The Theme 1 questions were settled with the owner (2026-06-22). They shape the
behaviour-changing Phases 4–5, not the behaviour-neutral Phases 1–3.

1. **Course creation stays admin-only → the global `instructor` role
   collapses.** Instructors do not self-serve course creation (admins do, as
   today), so there is no deployment-level "may create courses" capability to
   model. `instructor` becomes purely a per-course role; the only global role
   that survives the Phase 5 shrink is `admin`.
2. **`CourseRole` ships as `student` + `instructor` only; `ta` is deferred.**
   A TA rung (view/grade submissions, no suite edits) is a natural future
   addition but carries extra policy surface; the enum is string-backed, so it
   can be added later without a schema change.
3. **SSO mapping is deferred to Phase 5.** `SSO_INSTRUCTOR_USERS` /
   `SSO_ADMIN_USERS` keep their current global-role behavior through
   Phases 1–4 (which don't touch SSO). How an SSO "instructor" maps under the
   collapsed model is decided when the global role is shrunk.

### Still open (Theme 2)

4. **Term model depth.** Is a lightweight `Term` label enough, or do we want
   term-scoped enrollment (re-enroll each term) and cross-term analytics?
   Deferred with the rest of Theme 2.
