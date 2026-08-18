# Handoff — derive the authorization matrix over `CourseRole.allCases`

**Status: not started. This is the whole task.** The finding is in
[fitness-functions.md](fitness-functions.md); this is how to act on it.

## The defect

`Tests/APITests/RouteAuthorizationMatrixTests.swift` walks the **live route
table** (`app.routes.all`), takes every parameterized route under `/instructor`
and `/courses`, substitutes real fixture IDs, and asserts each route denies:

1. a **student** of the course that owns the resources, and
2. **staff (an instructor) of a different course**.

Routes are therefore *discovered* — a new route with an unknown path parameter
fails the walk until someone adds a fixture value. That half is right and should
not be disturbed.

The role dimension is not. `CourseRole` is `student < ta < instructor`, and
**`.ta` appears zero times in that file.** The TA boundary — a TA may author
content and grade, but may **not** manage enrollment, deadlines, archival or
staff — rests on **eight hand-written spot tests** in
`Tests/APITests/TARoleRouteTests.swift`.

So an instructor-only route that forgets its `.instructor` floor passes both:

- the matrix denies students and cross-course staff, and **a TA of the owning
  course is neither**;
- the spot suite only covers routes someone remembered to write a test for.

This is the *"enumerated rather than discovered, fails open"* shape the language
work was built to escape (`LanguageConformanceMatrixTests`' header tells that
story). It sits on the dimension where the failure mode is cross-course access
to student data rather than a mis-rendered test.

## The design problem — read this before writing code

The existing matrix works because its expected outcome is **uniform**: every
route denies both personas. A TA is *allowed* on most `/instructor` routes and
denied on a few, so there is no single expected outcome. The matrix needs to
know **each route's declared floor**, and the route table does not carry it.

Three ways to get it, in ascending order of how much they are worth:

1. **Scan the handler source for `requireCourseRole(atLeast:)`.** Cheap and
   fragile — it infers the invariant from an implementation detail, and a route
   whose gate is spelled differently reads as having no floor. This is the
   option that quietly fails open. Do not pick it.
2. **A declared floor map in the test**, keyed by route, with exhaustiveness
   enforced by the discovered route table: a route with no declared floor
   **fails** until someone declares it. Routes stay discovered, floors are
   stated once, and a new route cannot be forgotten. This is the recommended
   option — it is honest that a floor is a human judgement while keeping the
   fails-closed property.
3. **Declare the floor at route registration** so the test reads it off the
   route rather than off a parallel map. The principled end state: the
   invariant lives with the route it governs and cannot drift from it. More
   invasive; worth proposing separately if (2) proves annoying to maintain.

**Pick (2) unless you find a reason not to, and say why in the PR.**

## What to build

In `RouteAuthorizationMatrixTests`:

- Add a **third persona** to `fixture()`: a user with a `.ta` enrollment in
  OWNED. The existing fixture already shows the shape — `loginUser`, then an
  `APICourseEnrollment(userID:courseID:role:)`. Note the existing outsider is
  deliberately a *global student with a per-course role*, which also proves
  authority is per-course; keep that property.
- Add the declared-floor map, and fail on any walked route missing an entry,
  with the offending route named — mirroring how an unknown path parameter
  already fails.
- For each walked route, assert the TA persona is **denied** where the floor is
  `.instructor` and **not denied** where it is `.ta`. "Not denied" is the
  weaker assertion — a 200 is not required, only that it is not 401/403/404 for
  an authorization reason — so be careful the negative case is meaningful and
  not passing on an unrelated 404.
- Then delete from `TARoleRouteTests` only what the matrix now covers, and say
  in the PR what you removed and why. Leave anything asserting *behaviour*
  rather than *authorization*.

## How to know it is done

The repo's own rule applies and is not optional: **watch it fail.** A guard
never seen to fail is a hypothesis.

- Remove the `.instructor` floor from one genuinely instructor-only route (a
  deadline, archival, enrollment or staff-management route) and confirm the
  matrix goes red, naming that route.
- Add a new route with a floor and no map entry; confirm it fails until
  declared.
- Restore both, confirm green.

Consider adding a fixture to `scripts/guard-fixtures/` if the check can be
expressed as a defect + expected message (see `scripts/check-guards.sh`) — but
this is a Swift test, so the equivalent discipline is the two failure
demonstrations above, recorded in the PR description.

## Traps this codebase has already paid for

- **A test that hand-lists cases fails open.** That is the entire reason this
  task exists; do not replace one hand-list with another.
- **A weak proxy is not the contract.** `DatasetsRouteRoundTripTests` once
  asserted a field's visibility by searching a whole table row for the string
  `hidden`, which silently became a different question the moment anything else
  in the row rendered hidden. Assert the specific thing.
- **`.serialized` matters here.** This suite is DB-backed and already carries
  it; keep it.

## Definition of done

A new `/instructor` route cannot be added without declaring its floor, and a
route whose floor is wrong fails a named test — without anyone remembering to
write a test for it.
