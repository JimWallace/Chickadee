### Changed

- **The inline detail-row accordion moved out of `chickadee-ui.js` into
  `Public/accordion-row.js`** (`ChickadeeAccordion`), and picked up its first
  tests. It is the widget the suite table and the achievements table expand
  beneath a row, and it was living in the module `base.leaf` loads on every
  page for the sake of two authoring pages.

  No behaviour change; the two callers name it directly. What the eighteen new
  tests pin is the part that fails silently rather than loudly, because every
  one of its animation paths ends in a teardown and a teardown that does not run
  leaves a stranded detail row with an editor still mounted in it:

  - the open flips to `is-open` only on the SECOND animation frame — one frame
    does not reliably start the transition, and a transition that never starts
    is a row that never reveals its overflow, which clips the editor's popovers;
  - every animated path carries a timeout fallback, because `transitionend`
    does not fire in a backgrounded tab or under a `display: none` ancestor;
  - the teardown runs exactly once however it is reached: the caller's
    synchronous `finishNow()`, the transition and the fallback timer all race,
    and running `onDone` twice would tear down an editor body already rescued.
