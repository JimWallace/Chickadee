# Elementary views

Status: **migration done (October 2026).** Every page is an Elementary view
under `Sources/APIServer/Views/`, and the server no longer links Leaf or
renders a template. This document began as the record of a one-page spike
that ported a page from Leaf to
[Elementary](https://github.com/elementary-swift/elementary). It keeps what
the spike measured and found, the guards that replaced the Leaf-era scripts,
and what remains. The decision and its order are in "Decisions".

## Where things are now

- Pages: `Sources/APIServer/Views/Pages/`, one `HTML` type per page. Shared
  parts (the layout, the nav, the tab bars, the editor bodies) sit beside
  them in `Sources/APIServer/Views/`.
- Glue: `HTMLResponse` (the Vapor response) and `PageRequestContext` (CSRF
  token, version, idle timeouts, sprites).
- Sprites: `Resources/Sprites/icons.svg` and
  `Resources/Sprites/avatar-sprite.svg`, read once at startup by
  `Application.loadSprites()` and inlined by `BaseLayout` and `AvatarSprite`.
- Errors: `ErrorPageMiddleware` renders `ErrorPage` for browser routes.
- Leaf is gone from `Package.swift`. See "Known remainder" for why
  `Package.resolved` still lists it.

## What the spike did

- It adds Elementary 0.8 (pinned to the minor, because the package is pre-1.0)
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
| `Views/PageRequestContext.swift` | The request-scoped values that the Leaf custom tags read at render time: CSRF token, version, idle timeouts, icon sprite. These tags are now deleted. |
| `Views/BaseLayout.swift`, `Views/SiteNav.swift` | `base.leaf` and `_flash.leaf`. |
| `Views/MarkupAttribute+Chickadee.swift`, `Views/Icon.swift`, `Views/CSRFField.swift`, `Views/PageStyle.swift` | ARIA attributes, the icon, the CSRF input and the raw page CSS. Elementary ships none of these. |
| `Views/Pages/AdminUserPage.swift` | `admin-user.leaf`. |

## Results

### Output parity

A scratch test (not committed) rendered the page through Leaf and through Elementary for the
same data: an admin enrolled in two courses (so the nav menu and the course
tabs render) and a subject with one enrollment, one available course and a
course name that contains `<&>`. After normalisation (comments removed,
whitespace collapsed, quotes unified), 315 lines matched and three differed
on 0.6. None of the three is visible, and 0.8 removed the third:

- Leaf leaves a trailing space in `class="nav-dropdown-item "` and
  `class="course-tab "` when the active-class branch is false. Elementary
  merges classes and leaves none.
- On 0.6, Elementary wrote `<use href="#i-trash"></use>`, where Leaf writes
  `<use .../>`. On 0.8, SVG elements render self-closing, as Leaf does.

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

## Upgrade cost: 0.6.4 to 0.8.2

The spike was written on 0.6.4 and then moved to 0.8.2. Both 0.7 and 0.8 are
marked as breaking releases. For one page, a layout and five components, the
move cost:

- **One compile error.** `svg` became `SVG.svg`, a deprecation that strict
  warnings turn into an error.
- **One moved constraint.** Shared attributes now live on
  `MarkupAttribute where Tag: MarkupTrait.AllowsAttributes`, so the ARIA
  helpers moved there. They now apply to SVG elements too.
- **Less code.** 0.8 has an `SVG` namespace with `use`, so the hand-made
  `SVGUse` tag was deleted.
- **One changed byte sequence.** Empty SVG elements now render self-closing.
  One expectation in `ElementaryAdminUserPageTests` changed. The existing
  route tests did not.

The lockfile changed for Elementary only. For a full migration the cost grows
with the number of views that use a changed API, but each change was mechanical
and the compiler found every site.

## Traps found

1. **A stored property named `content` replaces the view.** Elementary's
   `HTML` protocol still declares a deprecated `var content` requirement. A
   stored `content` property satisfies it, so the `body` builder is not used
   and the compiler reports unused results instead. `BaseLayout` names it
   `pageContent`.
2. **The tests build the app without `AppMiddleware`.** The icon sprite was
   first loaded there, so every test page rendered with no icons and no
   error. `Application.sprite(_:)` now reads the file
   (`Resources/Sprites/`) when nothing loaded it.
   A failed read still yields an empty sprite with no error. A migration
   should make the sprite a Swift value, so that nothing is read at run time.
   The general rule: anything a view needs from startup must have a fallback
   or must fail loudly.
3. **The CSRF scraper in the tests matched Leaf's quote style.**
   `extractCSRFToken` looked for `name='_csrf' value='`. The CSRF package's
   Leaf tag writes single quotes, and Elementary writes double quotes. The
   helper now accepts both. This is the one change to existing test code.
4. **SwiftLint `type_name` rejects lower-case element types.** Elementary
   names elements in lower case (`div`). An element Chickadee adds in its
   own module must be upper case, or each one needs a suppression. On 0.6
   the spike added `SVGUse` this way. On 0.8 Elementary ships the SVG
   elements, so the spike adds none.
5. **Elementary models only some attributes.** There are no ARIA helpers,
   no predefined `role` values, and no `type` or `sizes` on `<link>`.
   Chickadee adds the ARIA helpers. The others use `.custom(name:value:)`.
   The type system rejected `.type(...)` on `<link>`. That is the intended
   behaviour, but each gap costs a small extension.
6. **Text inside `<style>` is escaped.** Elementary escapes the content of
   every element. A browser does not decode entities inside `<style>`, so a
   child selector `a > b` would arrive as `a &gt; b` and stop matching with
   no error. `PageStyle` emits the CSS raw, and takes a `StaticString` so that
   no data can be interpolated into it. The same applies to an inline
   `<script>`, which the CSP already forbids.
7. **Opaque helpers.** A `private func row(...) -> some HTML` used inside a
   `for` in a builder did not infer under the module-emitting build. A small
   `HTML` struct (`EnrolledCourseRow`) did. Prefer structs for repeated parts.

## Guards

During the migration the shell guards read `Resources/Views/*.leaf` and
nothing else, and they fail open: with a template deleted they check fewer
files and say nothing. So each guard got its Swift replacement before the
template it read was deleted. The table records the pairing. The Leaf-era
column is history; the Elementary column is what is in force.

### What guards the Elementary views

`ElementaryPageGuardTests` renders every page in `ElementaryPageFixtures`
(one render per branch worth checking) and applies the rules in
`RenderedMarkupRules` to the HTML. It fails when a page type under
`Views/Pages/` has no fixture, and each rule has a test that proves it fires.
Two SwiftLint custom rules (`elementary_no_inline_style`,
`elementary_raw_html`) catch the same mistakes in source, including branches
no fixture reaches.

| Rule | Leaf-era guard | Elementary guard | Status |
|---|---|---|---|
| No inline `style=""` except `display:none` or a custom property | `check-styles.sh` rule 2 | rendered-page test; SwiftLint `.style(` ban | Done |
| No inline script, no `on*=` handler | `check-styles.sh` rules 3b to 3b-3 | rendered-page test | Done |
| Every assigned class resolves | `check-class-resolution.sh` | rendered-page test, same stylesheet and allowlist | Done |
| Every `var(--x)` resolves, no hardcoded fallback | `check-css-vars.sh` (hex fallbacks only) | rendered-page test, page blocks and `style` attributes; any hardcoded fallback | Done, stricter |
| Hover text at most 20 words | `check-ui-vocabulary.sh` rule 3 (skips interpolated titles) | rendered-page test, every title | Done, stricter |
| Heading levels form a spine | `PageArchetypeTests` | rendered-page test | Done |
| Archetype shape | `PageArchetypeTests` | the same rules, applied to the rendered `<main>` of each exemplar fixture | Done |
| Raw HTML only where escaping is handled | none | SwiftLint `HTMLRaw(` ban outside `BaseLayout` (with `Doctype`), `AvatarSprite`, `JSONIsland` and `PageStyle` (checked by hand: a planted use fails lint) | Done |
| `ui-review` runs on a view change | workflow path filter | `Sources/APIServer/Views/**` added | Done |
| Design tokens in page CSS | `check-design-tokens.sh` | the same script reads `PageStyle` blocks (`scripts/lib/css.sh`) | Done |
| Page `<style>` total ratchet, duplicate and shadowed selectors | `check-styles.sh` rules 4 and 4b | the same rules count `PageStyle` blocks | Done |
| Flash banners only through the layout | `PageArchetypeTests` | SwiftLint `elementary_flash_only_in_layout` | Done |
| Tab bars only through their component | `PageArchetypeTests`, `check-ui-vocabulary.sh` | SwiftLint `elementary_tabs_only_in_component` keeps the tab classes in `AdminTabs` and `InstructorTabs`; `everyAdminTabbedPageOpensWithAdminTabs` and `everyInstructorTabbedPageOpensWithInstructorTabs` hold every tabbed page to one hidden h1 and one tab bar | Done |
| Component vocabulary, affordance registry in page CSS | `check-ui-vocabulary.sh` | the same script reads Swift views with a `PageStyle` block | Done |
| `base.leaf` and `BaseLayout` stay in step | none | `BaseLayoutParityTests` while both existed | Retired with `base.leaf` |
| Leaf semantics | `check-leaf-semantics.sh` | not needed: the compiler enforces it | Retired |

The archetype check reads only fixtures marked `isExemplar`.

### Leaf hardening (retired)

While Leaf pages were in service, two LeafKit traps were closed: a shared
`useChickadeeConfiguration` made a missing `#import` slot throw
(`LeafStrictImportTests`), and `check-leaf-semantics.sh` checked every tag
name against the registered tags. Both went with Leaf. The compiler now
rejects what they caught.

## A bug the port carried over, now fixed

`POST /admin/users/:id/enroll` redirects to `/admin/users/:id?error=invalid_course`
when the course ID is bad or the course is archived, but the Leaf page had no
flash field, so the error never showed. `AdminUserEnrollErrorTests` reproduced
it (the redirect was right, the page was silent), and the fix is one argument:
the route maps the code through `AdminEnrollError` to a fixed message and
passes it as `BaseLayout(flash:)`. An unknown code shows nothing, so no query
text reaches the page.

## What gets better

- The Leaf traps that CLAUDE.md used to list ("rules that fail silently";
  the evidence is in `docs/archive/leaf-decomposition-review.md`) cannot
  occur. A missing field, a wrong property, `.isEmpty` and a commented-out
  tag are compile errors or plain Swift.
- The view takes typed values. `AdminUserDetailContext` is gone, and the
  route passes `AdminCourseRef` values straight through.
- A view renders as a value, with no app, no database and no request.
  `ElementaryAdminUserPageTests` runs in 7 ms. The existing render tests need
  a database-backed app.
- The Leaf custom tags became plain properties on `PageRequestContext`.

## Decisions

0. **Migrate from Leaf to compiled Elementary views.** The compiler check on
   every template change is the reason: the Leaf bugs listed in "What gets
   better" were silent at render time, and a compile error is not. Pages move
   one archetype at a time, after the guards below.
1. **The edit loop is accepted.** Only administrators and developers edit
   templates. Everything else on a page is generated at run time, so a 30 to
   40 s rebuild for a template edit is acceptable.
2. **Guards first.** Each guard gets its Swift replacement, and the
   replacement lands, before the first template it reads is deleted. The
   `ui-review` path filter is part of this.
3. **Done.** The last page moved in October 2026. Leaf, its configuration
   and its custom tags are removed from the server; the error middleware is
   `ErrorPageMiddleware`.

## Open points

1. **Streaming.** `HTMLResponse` renders to one `String`. Elementary can
   stream with back-pressure; the spike does not need it.
2. **Environment values.** The spike passes `PageRequestContext` and the
   CSRF token explicitly. Elementary's `@Environment` reads a `TaskLocal`, and
   its `requiring:` form calls `fatalError` when the value is not set. Explicit
   parameters are safer.
3. **Order with Vapor 5.** Elementary does not depend on Vapor. If the views
   move first, the Vapor 5 move touches only `HTMLResponse` and
   `PageRequestContext`. See "Vapor 5 and Leaf: status (October 2026)".

## Vapor 5 and Leaf: status (October 2026)

Checked on 2026-10-10. Recheck before the Vapor 5 move. Since then the
migration finished, so point 4 below is settled: no page waits on a Vapor 5
Leaf. Only the transitive dependency in "Known remainder" does.

**Vapor 5 is in beta.** 5.0.0-alpha.1 shipped on 11 June 2026, beta.1 on
15 September and beta.3 on 1 October. The beta announcement calls it
"essentially a full rewrite": no `EventLoopFuture`, `Request` and `Response`
are structs on Swift HTTP Types, body decoding is async, middleware is
"still in progress", configuration moves to Swift Configuration, and the
testing library is new. There is no release date; the team says it depends
partly on the ecosystem packages. It requires Swift 6.4 and **macOS 26**.
`Package.swift` targets macOS 15, so the platform minimum must rise for the
move.

**Leaf does not support Vapor 5 yet.** The beta announcement says only
"Leaf integration will be available soon"; Fluent, JWT and Queues are also
listed as coming later.

- `vapor/leaf` (the Vapor integration) has no Vapor 5 branch. Its releases
  are Vapor 4 maintenance.
- `vapor/leaf-kit` (the engine) has a draft pull request, "LeafKit V2"
  (#137), on a `v5` branch. It holds four commits: removing futures and moving
  to Swift Testing (April 2025), then a merge from `main` and an import fix
  (April 2026). No review has been requested.
- The 5.0 documentation has no Leaf section and no migration guide yet.

**Vapor 5 keeps a renderer-neutral `View`.** Vapor pull request #3551 ("New
View Type", merged 9 September 2026) backs `View` with in-memory `Data`, and
its discussion decided against streaming templates. `HTMLResponse` already
renders one in-memory `String`, so the Vapor 5 port of the views is that type
and `PageRequestContext`, against the new `Response` and dependency
injection.

**What this means here.**

1. Staying on Leaf would hold the Vapor 5 move until a Leaf release for it
   exists. The only evidence of one is a draft with four commits.
2. With the views on Elementary, the Vapor 5 move for the view layer does not
   wait on Leaf.
3. Vapor 5 itself is not ready to adopt: it is a beta, its middleware is
   unfinished, and the community packages in use (`CSRF`, from
   vapor-community) need their own ports. The order stays: views to
   Elementary on Vapor 4 now, Vapor 5 after its final release.
4. The decision point for Leaf is the release of a Vapor 5 Leaf. If pages are
   still on Leaf then, choose between porting those pages to the new Leaf and
   finishing the Elementary migration first. A finished migration makes the
   Leaf release irrelevant.

Sources: [Vapor 5 Beta](https://blog.vapor.codes/posts/vapor-5-beta/),
[What's New in Vapor 5 Beta](https://blog.vapor.codes/posts/whats-new-in-vapor-5-beta/),
[Vapor releases](https://github.com/vapor/vapor/releases),
[vapor/vapor#3551](https://github.com/vapor/vapor/pull/3551),
[Vapor 5.0 docs](https://docs.vapor.codes/5.0/),
[vapor/leaf releases](https://github.com/vapor/leaf/releases),
[vapor/leaf-kit#137](https://github.com/vapor/leaf-kit/pull/137),
[vapor/leaf-kit releases](https://github.com/vapor/leaf-kit/releases).

## Known remainder

- **Leaf is still in `Package.resolved`.** `vapor-community/CSRF` depends on
  `vapor/leaf` for its own `CSRFFormFieldTag`, so `leaf` and `leaf-kit` stay
  in the resolved graph and are compiled as part of CSRF. Chickadee imports
  neither. Dropping them needs a CSRF release without the Leaf tag, or
  Chickadee's own CSRF middleware. The same package needs a Vapor 5 port
  anyway (see above).
- **Leaf-shaped view contexts.** Several context types still carry flat
  `Bool` flags and pre-rendered strings that existed only because Leaf could
  not evaluate compound conditions, `.isEmpty` or optionals (for example
  `hasAvatar`, `hasSpends`, `canRefund`, the BrightSpace panel gates and
  `AvatarPresentation.isLabelled`). Their comments say "kept from the Leaf
  templates". A view could compute these directly; that is a follow-up.
- **The sprite headers.** The comment at the top of each sprite file still
  mentions where the Leaf layout included it. The bytes were kept identical
  in the move.
