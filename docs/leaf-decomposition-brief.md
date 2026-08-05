# Brief: the Leaf "multi-extend bug", and what it was holding up

You are picking up an investigation that starts from a correction. For roughly
two months this repo believed a LeafKit parser bug made template decomposition
impossible. It does not exist. Something else, with a narrower and stranger
shape, was causing the failures. That was established in #1266 (2026-08); this
brief hands you the finding, the method that produced it, and the work it
unblocks.

Read `CLAUDE.md` → "Leaf partial decomposition" first — the verified table lives
there and is the short version. This document is the working context around it.

---

## 1. The bottom line

**Leaf's lexer has no notion of an HTML comment.** `<!-- ... -->` is raw text to
it, so Leaf tag syntax written inside a comment is lexed exactly as if it stood
in the markup.

That is the whole mechanism. Everything the old rule described follows from it:

| Written in a comment (or any prose) | What actually happens |
|---|---|
| a bare structural tag name — `extend`, `if`, `else`, `elseif`, `endif`, `for`, `endfor`, `import`, `export`, `endextend`, each with a leading `#` | **500 at render** |
| `#(someField)` | **silently interpolated** — the real context value is written into the served HTML |
| `#someTag()` | parens consumed, the name left behind as literal text |
| a *complete* `extend("_partial")` | **resolves the partial**, exactly as if it were not commented out |
| unknown `#word` (`#wb-single-edit`, `#jl-frame`), `C#`, `id="#main"` | genuinely inert |

The error the old rule was named after —
`LeafError.500: extend only supports one or two parameters []` — is the first
row. A bare tag name lexes to a tag with *no* parameter list, and `Extend.init`
rejects that. The empty `[]` in the message was literally saying "there are zero
parameters here", and nobody read it that way because it appeared next to a
perfectly good include.

**Multiple inline partial includes work.** So does the sub-context form,
`extend("_partial", subObject)`, which binds the partial against a nested object
— that is what lets one partial serve both a standalone page (flat context) and
a composite page (nested), as `_assignment-edit-body` and `_notebook-body` do
for the workbench today. Note the syntax: a bare second parameter. The labelled
`with:` form does **not** lex (`invalidParameterToken(":")`).

**The practical rule** is therefore narrower than the old one and different in
kind: never write Leaf *tag* syntax in template prose or comments. Say "the
extend" or "an `extend(...)` include". Commenting a tag out does not disable it.
Existing comments that name CSS ids (`#suite-sections`) are safe — that is the
last row of the table, and it is why the rule cannot just be "no `#` in prose".

---

## 2. How to verify anything in this area — read this before running a probe

The investigation that produced the table above **first produced a wrong
answer**, and the way it went wrong is the single most useful thing in this
brief.

A probe loop toggled a candidate token into a template, ran a `swift test
--filter`, and grepped the output for a pass marker. Every row came back
"BREAKS", which looked like a clean, dramatic result: *everything* breaks. It
was about to be written into `CLAUDE.md`.

The filter named a test that **does not exist**. `swift test` reported
`0 tests in 0 suites passed`, the grep matched nothing, and every row was
recorded as a failure. The harness measured nothing at all.

So:

- **Always run a no-probe control first.** If the control does not come back
  green, your harness is broken, not the code. The corrected run in #1266 starts
  with `CONTROL (no probe): OK` for exactly this reason.
- **Assert on a marker you have seen appear**, not on the absence of a failure.
- **Falsify every new assertion.** Delete the thing it tests and confirm it goes
  red before you keep it.

This is not generic advice in this codebase. Six assertions in the workbench
feature were green while testing nothing — including two written during the very
work that was hunting for them, and one that made a passing browser check report
OK against a `chrome-error://` page. Budget for it.

A worked example of the right shape, if you want one: render a probe into
`notebook.leaf` (7 lines, one include), assert the probe's marker appears in the
response body, then remove the probe and confirm the assertion fails. That pair
is what makes a Leaf claim trustworthy here.

---

## 3. What the old rule was holding up

`CLAUDE.md` said "at most **one** inline partial `extend` per template until the
parser bug is fixed — the multi-extend editor decomposition is on hold." Two
things follow.

**(a) The editor templates were never decomposed.** Current state:

| File | Lines |
|---|---|
| `Resources/Views/assignments.leaf` | 1160 |
| `Resources/Views/assignment-new.leaf` | 1059 |
| `Resources/Views/_assignment-edit-body.leaf` | 918 |
| `Resources/Views/admin.leaf` | 718 |

`_assignment-edit-body.leaf` was split out of `assignment-edit.leaf` in #1266,
but only at the outermost level — so the *page* is now a thin shell and the
*body* is still monolithic. Nothing below that has been touched.

**(b) `assignment-new.leaf` and the edit body duplicate real markup.** They are
the create and edit views of the same assignment, and they carry the same blocks
in two copies. Measured:

| Shared block | occurrences in `assignment-new` | in `_assignment-edit-body` |
|---|---|---|
| `suite-sections` | 9 | 6 |
| `check-schema` | 3 | 3 |
| `pattern-families-seed` | 2 | 2 |
| `suite-state-seed` | 1 | 1 |
| `notebook-files-table` | 1 | 1 |

Plus 16 and 22 `<script>` tags respectively, with substantial overlap in which
modules they load and how they initialise them. This is the drift risk the
decomposition was meant to remove: a change to the suite editor has to be made
twice, and nothing catches it if you only make it once.

**Your first job is to size this honestly, not to assume it.** The counts above
are occurrences of a marker string, which is a *signal* of shared structure, not
proof that the blocks are identical. Diff the actual regions before proposing a
shared partial — some of these deliberately differ (the create page has no
achievements block and no global-inputs block; a draft has no assignment ID).

---

## 4. What is genuinely uncertain

Be careful not to inherit my confidence where I did not earn it.

- **I verified the table on LeafKit 1.14.3 only** (`Package.resolved`;
  `leaf` 4.5.2 / `leaf-kit` 1.14.3). I did not check other versions, and I did
  not read enough of the lexer to say *why* unknown `#word` is inert while known
  tag names throw. If your work depends on that distinction holding, confirm it
  in `.build/checkouts/leaf-kit/Sources/LeafKit/LeafSyntax/`.
- **I did not test nesting depth.** The workbench chain is
  `workbench → _assignment-edit-body → _family-editor-body`, three levels, and
  it renders. Deeper is unknown.
- **I did not test how many includes one template tolerates.** Two work. The
  old rule's "template size matters" claim was almost certainly a
  misattribution — the heavily-commented templates were the ones with tag names
  in their prose — but I did not disprove a size effect directly.
- **Render tests prove templates resolve, not that pages work.** They do not
  exercise page JS. Anything with a JS-driven widget (the suite table, the
  pattern-family editor, the check editor) needs a real browser check. The
  workbench has one at `Tools/editor-smoke-test/workbench-check.mjs`; run it
  with `SMOKE_CHECK=workbench-check.mjs SMOKE_BROWSER=chromium
  Tools/editor-smoke-test/run-smoke.sh`, and set `SMOKE_BROWSER_PATH` if this
  machine's Chromium build differs from the pinned Playwright's.

One live hazard worth knowing about before you split anything: `innerHTML` is
**not** a safe way to move server-rendered markup around. It serializes to text
and re-parses, which destroys element identity — that bug cost a real debugging
cycle in #1267 and left `notebook.js` bound to a detached node. If a
decomposition needs to preserve an element across a swap, use `importNode` into
a fragment. See `swapHalf` in `Public/chickadee-ui.js`.

---

## 5. Deliverable

Not a refactor on day one. What is actually wanted first:

1. A short written answer to "what does the corrected rule make possible that
   the old one forbade?" — grounded in diffs of the duplicated regions above,
   not in line counts.
2. A recommendation on whether the `assignment-new` / edit-body duplication is
   worth removing, with the risk stated. These are the two highest-traffic
   authoring surfaces in the product; a shared partial that gets the create-vs-edit
   differences subtly wrong is worse than two honest copies.
3. If the answer is yes: a slice plan, smallest first, each slice independently
   shippable and each with a falsified assertion.

If the answer is no, say so. "The rule was wrong and the work it blocked is not
worth doing anyway" is a completely acceptable outcome, and cheaper to discover
now than halfway through.

---

## 6. Where the evidence is

- `CLAUDE.md` → "Leaf partial decomposition" — the verified table and the rule.
- PR #1266 — the merge that produced the finding; the commit correcting
  `CLAUDE.md` explains the control-first method and why the first answer was wrong.
- PR #1267 — the `innerHTML`/`importNode` hazard, and the view-control bug that
  was hiding behind an assertion clicking a control that was already active.
- `Resources/Views/_notebook-body.leaf`, `_assignment-edit-body.leaf` — the two
  partials that already do the sub-context thing, as working reference.
- `Sources/APIServer/Routes/Web/AssignmentEditorContexts.swift` —
  `AssignmentWorkbenchContext` shows how a nested context is shaped so one
  partial serves two pages.
