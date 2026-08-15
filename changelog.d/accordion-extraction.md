### Changed

- **The inline detail-row accordion moved out of `chickadee-ui.js` into
  `Public/accordion-row.js`** as `ChickadeeAccordion`. It is the widget the
  suite table and the achievements table expand beneath a row — a thing with its
  own DOM contract and its own animation rules, not a shared utility in the
  sense that escaping a string is — and it was living in the module `base.leaf`
  loads on every page for the sake of two authoring pages.

  No call site changes: `ChickadeeUI.accordion` remains the call surface. Every
  member resolves at call time, `CARET_HTML` included, which is why it is a
  getter rather than a value — the two files load as siblings, and reading the
  caret eagerly would capture `undefined` in whichever order put this one first.

  It also picks up its first nineteen tests. What they pin is the part that
  fails silently rather than loudly, because every one of its animation paths
  ends in a teardown and a teardown that does not run leaves a stranded detail
  row with an editor still mounted in it:

  - the open flips to `is-open` only on the SECOND animation frame — one frame
    does not reliably start the transition, and a transition that never starts
    is a row that never reveals its overflow, which clips the editor's popovers;
  - every animated path carries a timeout fallback, because `transitionend`
    does not fire in a backgrounded tab or under a `display: none` ancestor;
  - the teardown runs exactly once however it is reached: the caller's
    synchronous `finishNow()`, the transition and the fallback timer all race,
    and running `onDone` twice would tear down an editor body already rescued.
