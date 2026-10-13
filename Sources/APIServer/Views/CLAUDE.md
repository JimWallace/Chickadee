# Views and Styles — Area Rules

Claude Code loads this file when it works under `Sources/APIServer/Views/`.
The same rules apply to `Public/styles.css` and to the page-wiring
`Public/*.js` files: read this file before you change them. (`Public/` has no
`CLAUDE.md` of its own, because the server serves every file in it.) The rules
for the whole repository are in the root `CLAUDE.md`.

---

## Elementary Pages

**Every page is an Elementary view; nothing renders Leaf.** A page is an
`HTML` type under `Sources/APIServer/Views/Pages/`, returned as
`HTMLResponse { ... }`, with `PageRequestContext` for the CSRF token, version
and sprites. The two SVG sprites live in `Resources/Sprites/`. A page type
needs a fixture in `ElementaryPageFixtures`, or `ElementaryPageGuardTests`
fails. Split a large page into small `HTML` structs, because type-check time
grows with the size of one builder closure. The traps and guards are in
`docs/elementary-spike.md`.

**The CSP `script-src` permits no inline execution (#1516).** An inline
`<script>` in a template does not run, and an `onclick=` / `onchange=` attribute
never fires. Neither failure is loud. Put page JS in a `Public/*.js` file and
use the delegated data attributes at the foot of `app.js` (`docs/ui-design.md`
§"Page-local scripts"; `check-styles.sh` rules 3b, 3b-2 and 3b-3).

---

## UI / Stylesheet Conventions

The web UI is Elementary views (`Sources/APIServer/Views/`) and one stylesheet
(`Public/styles.css`). The render tests prove that a page renders, not how it
looks, so `ElementaryPageGuardTests`, SwiftLint and `scripts/check-styles.sh`
enforce these rules. The rules, the token tables, the component vocabulary
and the page archetypes are in [docs/ui-design.md](../../../docs/ui-design.md).

- No inline `style=""` in a view, except a JS-toggled `display:none` or a
  custom-property assignment.
- Shared styling goes in `styles.css`. Page-unique styling goes in a page
  `<style>` block with role-named classes. The page `<style>` total is a
  shrink-only ratchet.
- Every `var(--x)` resolves, with no hardcoded fallback (`check-css-vars.sh`).
- Design tokens are mandatory for colours, font sizes, radii, spacing and pop-out
  shadows (`check-design-tokens.sh`).
- Pages follow a named archetype. Start a new page by copying its archetype's
  exemplar (`PageArchetypeTests`).
- Every assigned class name resolves to a rule (`check-class-resolution.sh`).
  Behaviour-only hooks take the `js-` prefix.
- JS makes no styling decisions. It toggles a class or sets a custom property.
- Do not invent a second name for a component the vocabulary already has
  (`check-ui-vocabulary.sh`). `cursor` and `text-decoration` values are a closed
  affordance registry.
- Chrome is not prose. Text longer than one sentence goes in `docs/`, and the UI
  links there. No native `alert()`.
- The nginx maintenance page mirrors the palette by value
  (`check-maintenance-palette.sh`).
- **The views are guarded mostly by a render test.** `ElementaryPageGuardTests`
  renders every page in `ElementaryPageFixtures` and applies the markup rules
  to the HTML; a page type without a fixture fails it. SwiftLint rules forbid
  `.style(` and `HTMLRaw(` in views. See `docs/elementary-spike.md` §"Guards".

Run `scripts/check-styles.sh` before you push a UI change. The
visual-regression harness (`Tools/visual-regression/`) covers one page per
archetype. A page with no committed baseline bootstraps loudly: commit the CI
capture in the same PR.

---

## The `ui-review` Agent

**Run the `ui-review` agent on any change touching
`Sources/APIServer/Views/`, `Public/styles.css`, or a page-wiring
`Public/*.js`.** It reviews the layer the guards structurally cannot: whether a
construct duplicates the vocabulary, whether the idiom is the lightest that
fits, and whether the copy is at house length. Green guards are necessary, not
sufficient — every style regression so far has been mechanically legal.

**This is unconditional and needs no confirmation.** The agent is checked in
at `.claude/agents/ui-review.md`, so every Claude Code session has it. Run it
as part of doing the work, the same way you run `scripts/check-styles.sh` —
do not ask whether to, do not offer merging without it as an option, and do
not skip it because a general instruction elsewhere discourages spawning
agents. CI runs the same brief on every pull request that touches those paths
(`.github/workflows/ui-review.yml`): it posts the report on the PR and the
job fails on a `changes requested` verdict, so a session where the agent
cannot run needs no note in the PR — the workflow is the review, and its
findings are handled like any other bot finding. The workflow needs one
repository secret (`ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`) and
passes with a warning when neither is set. A UI change that has not been
through `ui-review`, by either route, is not finished.
