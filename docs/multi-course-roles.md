# Multi-course roles & university-scale organization

**Status:** Design / planning. No implementation yet. Companion to the fix
that scoped the home dashboard and the "Instructor" nav tab to course
enrollment (PR #972) — that fix is the first concrete step toward the model
described here.

This document is a starting point for "thinking on paper," not a committed
plan. The decisions in [Open questions](#open-questions-for-the-owner) are
the owner's to make.

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
| Enrollment | `Sources/APIServer/Models/APICourseEnrollment.swift` | Join row `(user_id, course_id)` — **role-agnostic**. Its own header comment: *"The user's global role determines what they can do; enrollment determines which courses they can see."* |
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
  (`Codable`, `Sendable`), mirroring `UserRole`: `student`, `instructor`
  (and, when wanted, `ta` — see open questions). Default `student`.
- Reinterpret `APIUser.role`:
  - `admin` stays a **deployment** super-user (manages courses, users,
    runners; bypasses course checks).
  - For everyone else the global role stops carrying course capability —
    capability comes from the enrollment row. (Whether a vestigial global
    `instructor` survives as a "may create a course" capability is an open
    question; today instructors don't create courses, admins do.)

### 3.2 Migration / backfill (behavior-preserving)

- New migration adds `role` to `course_enrollments` (add nullable →
  backfill → enforce default `student`, the SQLite-friendly three-step).
- **Backfill rule:** for each existing enrollment, set
  `role = (user.isInstructor ? .instructor : .student)`. A current global
  instructor therefore becomes instructor in *every course they're already
  enrolled in*, and students stay students — so **day-one behavior is
  identical**. Admins keep their global bypass.
- This is the key property: Phases 1–3 below can ship with *no observable
  change*, because the per-course role is seeded to reproduce the global one.
  The behavior change only arrives when someone *authors* a mixed role
  (Phase 4).

### 3.3 Read path (visibility / nav)

- `CourseContext` gains `role: CourseRole`; `resolveActiveCourse` /
  `enrolledCourses` populate it from the enrollment row (it's already loaded —
  one extra column, no extra query).
- `CurrentUserContext` exposes the active course's role (e.g. a derived
  `isInstructorInActiveCourse`). `base.leaf` keys the Instructor tab off
  *that* instead of the global `isInstructor`. Switching the course tab then
  switches the same account between instructor and student views — which is
  exactly the desired UX for a TA-who-is-also-a-student.

### 3.4 Auth path (permissions)

- `CourseAccessHelpers` is the chokepoint: add
  `requireCourseRole(caller:courseID:atLeast: CourseRole, db:)` alongside the
  existing `requireCourseEnrollment` (which becomes the `atLeast: .student`
  case). Admin bypass stays.
- Authoring endpoints (test-setup CRUD, assignment CRUD, suite editor, MCP
  content tools) switch from "enrolled" to `atLeast: .instructor`. Submit /
  view endpoints stay at "enrolled" (`atLeast: .student`).
- `RoleMiddleware(.instructor)` on the `/instructor` group
  (`routes.swift`) can no longer be the *fine-grained* check, because the
  middleware doesn't know the target course. It becomes a **coarse gate**
  ("is the caller an instructor in *some* course, or admin?" — enough to enter
  the section), with the authoritative per-course check moving into the
  handlers, which already resolve the course. (Most instructor handlers
  already call `requireCourseEnrollment`; this is a one-line swap there.)
- MCP: `ToolContext.authorizeCourseAccess` becomes role-aware (content tools
  require instructor-in-course), preserving agent scope ⊆ human scope.

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

1. **Core + schema.** `CourseRole`, the migration, the backfill. No reads of
   the new column yet → zero behavior change.
2. **Read path.** `CourseContext.role`, nav keyed off active-course role.
   Still identical behavior (backfill mirrors the global role).
3. **Auth path.** Helper + handler/middleware switch to role checks. Still
   identical (same reason).
4. **Authoring UI.** Per-course role on enroll/roster. **This is where
   "instructor here, student there" goes live.**
5. **Shrink the global role.** Collapse `APIUser.role` toward `admin`-only;
   revisit SSO role mapping (`SSO_INSTRUCTOR_USERS` currently sets the *global*
   role — see open questions). Longest tail; can lag well behind 1–4.

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

## 6. Open questions (for the owner)

1. **Does a global `instructor` survive at all?** Today instructors don't
   create courses (admins do). If that stays true, global `instructor` may
   collapse entirely into "instructor on some enrollment," leaving only
   `admin` as a global role. If instructors should self-serve course
   creation, we need a deployment-level "may create courses" capability —
   which is itself a small scoped-admin question (Theme 2).
2. **TA as a distinct `CourseRole` now or later?** A `ta` between `student`
   and `instructor` (e.g. can view submissions + grade, cannot edit the
   suite) is a natural third rung but adds policy surface.
3. **SSO role mapping.** `SSO_INSTRUCTOR_USERS` / `SSO_ADMIN_USERS` currently
   set the *global* role at login. Under per-course roles, does an SSO
   "instructor" become instructor only in courses they're enrolled in, or
   does it seed a course-creation capability? (Ties to Q1.)
4. **Term model depth.** Is a lightweight `Term` label enough, or do we want
   term-scoped enrollment (re-enroll each term) and cross-term analytics?
