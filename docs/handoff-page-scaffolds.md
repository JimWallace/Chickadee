# Handoff — make the compliant page the easy one to start from

**Status: not started.** This is the additive half of the UI-language work.

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

Run the `ui-review` agent on whatever you build — it reviews the layer the
guards structurally cannot, which is the layer this work lives in.
