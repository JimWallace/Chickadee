# Elementary spike

Status: **spike, for a decision.** This document records what one page cost to
port from Leaf to [Elementary](https://github.com/elementary-swift/elementary),
what the port found, and what a full migration would need. It does not
decide the migration.

## What the spike does

- It adds Elementary 0.6 (pinned to the minor, because the package is pre-1.0)
  to `APIServer`.
- It ports `base.leaf`, `_flash.leaf` and the titlebar exemplar
  `admin-user.leaf` to Swift under `Sources/APIServer/Views/`.
- `GET /admin/users/:userID` returns `HTMLResponse { AdminUserPage(...) }`.
  The other 79 pages still render through Leaf, through the same base layout
  markup.
- `admin-user.leaf` stays in the tree, unused by the route.
  `PageArchetypeTests` reads it as the titlebar exemplar, and the style guards
  read it. See "Guards" below for why removing it is a decision, not a cleanup.

| File | Role |
|---|---|
| `Views/HTMLResponse.swift` | The Vapor glue: about 15 lines. Owned here, not taken from `vapor-community/vapor-elementary` (8 commits, no release). |
| `Views/PageRequestContext.swift` | The request-scoped values that the Leaf custom tags read at render time: CSRF token, version, idle timeouts, icon sprite. |
| `Views/BaseLayout.swift`, `Views/SiteNav.swift` | `base.leaf` and `_flash.leaf`. |
| `Views/HTMLAttribute+Chickadee.swift` | ARIA attributes, the SVG `use` element, `Icon` and `CSRFField`. Elementary ships none of these. |
| `Views/Pages/AdminUserPage.swift` | `admin-user.leaf`. |

## Results

### Output parity

A scratch test rendered the page through Leaf and through Elementary for the
same data: an admin enrolled in two courses (so the nav menu and the course
tabs render) and a subject with one enrollment, one available course and a
course name that contains `<&>`. After normalisation (comments removed,
whitespace collapsed, quotes unified), 315 lines matched and three differed.
None of the three is visible:

- Leaf leaves a trailing space in `class="nav-dropdown-item "` and
  `class="course-tab "` when the active-class branch is false. Elementary
  merges classes and leaves none.
- Elementary writes `<use href="#i-trash"></use>`. Leaf writes `<use .../>`.

The existing route tests (`AdminCourseTermLabelTests`,
`LeafEmptyStateRenderTests`, `AdminRoutesTests`) pass on the Elementary page
without change.

### Compile cost

Measured with `-warn-long-function-bodies=25` and
`-warn-long-expression-type-checking=25` on Linux x86_64, Swift 6.4:

| Body | Type-check time |
|---|---|
| `BaseLayout.body` | 72 to 80 ms |
| `BaseLayout.documentHead` | 44 ms |
| `SiteNav.staffEntry(for:)` | 38 to 40 ms |
| `AdminUserPage.enrolledSection` | 63 to 87 ms |
| `AdminUserPage.addSection` | 26 to 28 ms |
| `EnrolledCourseRow.body` | 26 to 27 ms |

The layout and the page together cost about 0.3 s of type checking. The
slowest view body (87 ms) is in the same range as the slowest existing
`APIServer` bodies (74 ms in `JupyterLiteAppIndexMiddleware`). `Core` holds
one 1.2 s expression today, for comparison.

`admin-user.leaf` is 81 lines and costs about 0.14 s. A linear estimate for
all 9,100 lines of templates is about 16 s of single-core type checking,
spread over the parallel compile. That is acceptable. The risk is not linear:
type-check time grows with the size of one builder closure, so a large page
must be split into small `HTML` types. `EnrolledCourseRow` had to be split out
for a different reason (see "Traps").

An incremental rebuild after a change to any `APIServer` file takes 30 to 40 s.
That is the size of the module, not the views. It is the real cost to an
author: a copy change in a Leaf template needs no rebuild.

### Escaping

Text escapes `&`, `<` and `>`. Attribute values are always double-quoted and
escape `&` and `"`. That is enough to keep a value inside its attribute.
`ElementaryAdminUserPageTests.userTextIsEscapedInTextAndAttributes` pins it.
Raw output is `HTMLRaw`, and `grep HTMLRaw` finds every site. The spike has
two: the doctype and the icon sprite.

## Traps found

1. **A stored property named `content` replaces the view.** Elementary's
   `HTML` protocol still declares a deprecated `var content` requirement. A
   stored `content` property satisfies it, so the `body` builder is not used
   and the compiler reports unused results instead. `BaseLayout` names it
   `pageContent`.
2. **The tests build the app without `AppMiddleware`.** The icon sprite was
   first loaded there, so every test page rendered with no icons and no
   error. `Application.iconSprite` now reads the file when nothing loaded it.
   The general rule: anything a view needs from startup must have a fallback
   or must fail loudly.
3. **The CSRF scraper in the tests matched Leaf's quote style.**
   `extractCSRFToken` looked for `name='_csrf' value='`. The CSRF package's
   Leaf tag writes single quotes, and Elementary writes double quotes. The
   helper now accepts both. This is the one change to existing test code.
4. **SwiftLint `type_name` rejects lower-case element types.** Elementary
   names elements in lower case (`div`, `svg`). An element Chickadee adds in
   its own module must be upper case (`SVGUse`), or each one needs a
   suppression.
5. **Elementary models only some attributes.** There are no ARIA helpers,
   no predefined `role` values, and no `type` or `sizes` on `<link>`.
   Chickadee adds the ARIA helpers. The others use `.custom(name:value:)`.
   The type system rejected `.type(...)` on `<link>`. That is the intended
   behaviour, but each gap costs a small extension.
6. **Opaque helpers.** A `private func row(...) -> some HTML` used inside a
   `for` in a builder did not infer under the module-emitting build. A small
   `HTML` struct (`EnrolledCourseRow`) did. Prefer structs for repeated parts.

## Guards

The UI guards read `Resources/Views/*.leaf` and nothing else. When
`admin-user.leaf` is deleted, all of `check-styles.sh`,
`check-class-resolution.sh`, `check-ui-vocabulary.sh`,
`check-leaf-semantics.sh`, `check-design-tokens.sh` and `check-css-vars.sh`
still pass. They fail open: they check fewer files and say nothing. Only
`PageArchetypeTests` fails, because it opens the exemplar by name. The
`ui-review` path filter (`Resources/Views/`, `Public/styles.css`,
`Public/*.js`) also does not match `Sources/APIServer/Views/`.

A migration must replace each guard before it removes the template the guard
reads. The options per rule:

| Rule | In Swift |
|---|---|
| No inline `style=""` | A SwiftLint custom rule on `.style(` under `Views/`. |
| Every class resolves to a rule | Render each page in a test and run the existing resolver on the HTML. Or move class names to a closed enum. |
| Component vocabulary, affordance registry | Closed enums or small component types (`Icon`, `CSRFField` are the start). |
| Page `<style>` ratchet | Count `style {` blocks under `Views/Pages/`. |
| Archetype exemplars | `PageArchetypeTests` must read the Swift exemplar, or a rendered page. |
| Leaf semantics (`check-leaf-semantics.sh`) | Not needed. The compiler enforces it. |

A rendered-HTML guard is the most direct port, because the existing scanners
already parse markup. It needs a fixture per page, so it costs more than a
file scan.

## What gets better

- The traps in CLAUDE.md "Leaf templates: rules that fail silently" cannot
  occur. A missing field, a wrong property, `.isEmpty` and a commented-out
  tag are compile errors or plain Swift.
- The view takes typed values. `AdminUserDetailContext` is gone, and the
  route passes `AdminCourseRef` values straight through.
- A view renders as a value, with no app, no database and no request.
  `ElementaryAdminUserPageTests` runs in 7 ms. The existing render tests need
  a database-backed app.
- The Leaf custom tags become plain properties on `PageRequestContext`.

## Open points for the decision

1. **The edit loop.** A template edit becomes a 30 to 40 s rebuild. Is that
   acceptable to the people who edit copy?
2. **Guards first.** The guard replacements above are the larger part of the
   work. They must land before the first template is deleted.
3. **Streaming.** `HTMLResponse` renders to one `String`. Elementary can
   stream with back-pressure; the spike does not need it.
4. **Environment values.** The spike passes `PageRequestContext` and the
   CSRF token explicitly. Elementary's `@Environment` reads a `TaskLocal`, and
   its `requiring:` form calls `fatalError` when the value is not set. Explicit
   parameters are safer.
5. **Order with Vapor 5.** Elementary does not depend on Vapor. If the views
   move first, the Vapor 5 move touches only `HTMLResponse` and
   `PageRequestContext`.

## To remove the spike

Revert the route in `AdminRoutes.swift` to `req.view.render("admin-user", ...)`,
restore `AdminUserDetailContext`, delete `Sources/APIServer/Views/`, the two
test files and the `loadIconSprite()` call, and remove the package from
`Package.swift`. `extractCSRFToken` can keep accepting both quote styles.
