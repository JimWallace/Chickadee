# Handoff — make the compliant page the easy one to start from

**Status: steps 1, 2 and 4 shipped. Step 3 (the component gallery)
deliberately not built — the condition for revisiting it is at the bottom.**
This was the additive half of the UI-language work.

What shipped:

- **An exemplar per archetype**, in the [ui-design.md](ui-design.md) table's
  new *Copy this* column: `alerts.leaf`, `instructor-mcp.leaf`,
  `admin-user.leaf`, `account.leaf`, `register.leaf`,
  `assignment-edit.leaf`, `workbench.leaf`.  Chosen on measured grounds —
  fewest page-private class names, least page CSS, no page script, and the
  fullest demonstration of the skeleton — not on which page was listed
  first.  `instructor-mcp.leaf` shed a vestigial empty `<style>` block to
  take its row.
- **`Tests/APITests/PageArchetypeTests.swift`**, which reads the exemplar
  column out of that table rather than restating it, and re-checks each
  exemplar against its own row.  The tag-walking it needs was extracted from
  `ListFilterMarkupTests` into `LeafMarkupScanner` rather than copied, so
  the two markup-contract guards share one implementation.
- **Redirects instead of refusals** in `scripts/check-ui-vocabulary.sh`: the
  catalog error now names the catalog components a rejected name is built
  out of (`dataset-estimate-chip` → `chip`), the affordance registry carries
  what each registered value already *means* rather than only its spelling,
  and the hover-prose refusal prints the cheapest-first reveal ladder.
- **Five fixtures** under `scripts/guard-fixtures/`.  That guard was the
  newest in the repo and had none, so all three of its rules were unproven —
  including the two this change rewrote.

Two things worth knowing before extending this.

**The suite proves it can fail.** Every assertion in it is of the form "this
list is empty", which an emptied-out rule satisfies perfectly. So the rules
are pure functions from a page to the ways it breaks them, and
`theArchetypeRulesTellTheSevenShapesApart` runs all forty-two off-diagonal
pairs — each archetype's rules against each other archetype's exemplar —
failing if any pair comes back clean.  Writing that test is what forced the
full-bleed rules to say something specific: without "a full-bleed page owns
markup", its rules accepted the eight-line body-partial shim.

**The exemplar is held to more than the archetype.** `submit.leaf` is a
perfectly good plain student page with no `.page-section` in it; `account.leaf`
may not lose its sections while it is the reference.  Nothing fails a page for
not being an exemplar.

## The question behind it

*"How do we lock down the UI language and keep shipping features without
reining in random changes all the time?"*

The honest diagnosis: **every investment in this codebase's UI language is
subtractive.** Guards say *no* — not that colour, not that class, not a second
chip, not a paragraph in a tooltip. There is nothing **additive** that says
*start here*. A new page is assembled by reading a 500-line rulebook and
imitating whichever existing page the author happened to open, and then the
guards argue with the result.

That is why drift keeps arriving through the front door. The token guards are
airtight and the vocabulary is now priced (#1445), but neither makes the
compliant thing the *cheapest* thing to begin.

Note what this is **not**: the "vertical slice" advice from the article that
prompted the question is about *sequencing work* (DB → server → UI, one feature
at a time), and this project is well past needing that. The thing worth having
is a **scaffold**, and it is genuinely absent.

## What exists, and what is missing

[ui-design.md](ui-design.md) defines **seven page archetypes** in a table:
Admin tabbed, Instructor tabbed, Titlebar page, Plain student page, Auth box,
Body-partial shim, Full-bleed app. Each row lists three example pages.

- The table **describes** skeletons in prose. It does not **provide** one.
- No example is designated canonical — three are listed, so an author picks
  whichever they open, and any drift in that page propagates.
- **Nothing checks archetype conformance.** Grep `archetype` across `scripts/`
  and `Tests/`: zero hits. `CLAUDE.md` asserts "Pages follow a named archetype"
  as though enforced; the only mechanism it cites is `PAGE_STYLE_BASELINE`,
  which counts CSS lines and knows nothing about shape.

So the archetype is the single most-repeated UI concept in the rulebook and the
least enforced thing in the repo.

## The work, cheapest first

**1. Name a canonical exemplar per archetype (small, do this first).**
Pick one existing page per row — the one that best embodies the skeleton — and
mark it in the table as *the* reference. No new files. The value is that
"copy `admin-alerts.leaf`" becomes a real instruction instead of "read the
skeleton column and infer".

**2. Guard the exemplars (small, and it is what makes (1) stick).**
A structural test asserting each exemplar still matches its archetype: the
tabbed ones open with the right partial and start sections at `<h2>`, the
titlebar one has `.page-titlebar` with a single `<h1>`, the auth box uses
`.auth-box`, exactly one `<h1>` per non-tabbed page, `_flash` is the only
banner source. `Tests/APITests/ListFilterMarkupTests.swift` is the pattern to
copy — it walks tags backwards from a match rather than grepping the document,
which is the right technique here for the same reason (a scanner cannot tell
markup from prose about markup, and this codebase has been bitten by that four
times).

Guarding the exemplar is deliberately weaker than guarding every page. It is
also achievable, and it means the thing authors copy cannot rot.

**3. Consider a component gallery (larger, decide after 1–2).**
A single page rendering every component in the vocabulary from the real
stylesheet — chips, tiers, buttons in their two sizes, the filter, the modal
shell, the popover, the stat tiles. It makes the vocabulary *discoverable at
the point of use* rather than by reading a document, and it doubles as a visual
baseline for the whole component set. Add it to
`Tools/visual-regression/pages.mjs` if built.

Do not start here. It is the most appealing and the least certain: if authors
do not open it, it is a page to maintain for nothing. Earn it with (1) and (2).

**4. Make the guards point at the alternative (small, high leverage).**
`scripts/check-ui-vocabulary.sh` currently says "reuse what is there" without
saying *what*. Error messages that name the nearest existing component turn a
refusal into a redirect. This is the cheapest way to make the subtractive layer
feel additive, and it needs no new machinery.

## Judgement calls to make deliberately

- **Do not add an eighth archetype** to solve a layout problem. The rulebook
  says so and means it; if a page genuinely does not fit, that is a
  conversation, not a new row.
- **Resist generating scaffolds.** A `new-page.sh` that stamps out a template is
  tempting and creates a second source of truth that drifts from the exemplar.
  Prefer "copy this page" over "run this generator" until there is evidence the
  copying is the bottleneck.
- **A scaffold is not a rule.** Nothing here should become a guard that fails an
  existing page for not being the exemplar. The point is to lower the cost of
  starting right, not to add a new way to be wrong.

## Definition of done

An author asking "how do I start a new instructor page?" gets a one-line answer
naming a file to copy, and that file cannot silently stop being a good example.

Both halves are now true: the answer is `instructor-mcp.leaf`, and
`PageArchetypeTests` fails if it stops being a good answer.

Run the `ui-review` agent on whatever you build — it reviews the layer the
guards structurally cannot, which is the layer this work lives in.

## Why the gallery was not built, and what would change that

Step 3 remains the most appealing and least certain item, and the argument
against starting there survived doing steps 1, 2 and 4: a gallery is a page to
maintain, it needs a visual baseline of its own, and nothing yet says authors
would open it.  Steps 1 and 2 are also the cheaper test of the same
hypothesis — that discoverability is what is missing — because they cost no new
page at all.

Build it when there is evidence the *exemplar* is not enough, and the evidence
is specific: a new page that copied the right exemplar and still reached for a
component that already existed under another name.  That is the failure a
gallery prevents and an exemplar cannot, because an exemplar only shows the
components its own archetype happens to use.  Until such a page exists, the
gallery would be answering a question nobody has asked.

Two smaller things are worth doing before it, if this comes back around:

- **Widen the redirect.** The catalog suggester finds names *built out of* a
  catalog component's name.  It cannot find the case the rulebook says is
  typical — a duplicate under a name sharing no word with its twin.  Nothing
  short of a concept index would, and a gallery is one form of that.
- **The exemplars have no visual baseline of their own.**
  `Tools/visual-regression/pages.mjs` covers `alerts`, `account` and `login`;
  the other four exemplars are structurally guarded but not pixel-guarded.
  Adding them is cheap and independent of the gallery question.
