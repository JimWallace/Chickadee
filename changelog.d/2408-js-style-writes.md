### Fixed

- **The JS styling ratchet counts writes, and all of them.** It counted a read in `jl-cell-perf-patch.js` and missed `el.style[prop] =`, `setAttribute('style', …)` and a `<style>` element built in JS. It now counts writes only, in every form. The true count is 10, so the baseline moves from 9 to 10 with no new code. (#2408)
