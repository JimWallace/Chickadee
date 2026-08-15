// Public/surface-swap.js
//
// Re-rendering half of the merged assignment workbench in place, without
// navigating.
//
// Split out of chickadee-ui.js, which had accumulated eighteen unrelated
// functions behind one name. This is the largest of those concerns and the one
// with the most rules of its own: a fetch, a parse, a node-identity discipline,
// and the only place in the frontend that deliberately turns markup into
// running code.
//
//   ChickadeeSurfaceSwap.refreshEditSurface()
//   ChickadeeSurfaceSwap.refreshNotebookSurface(url)
//
// `ChickadeeUI` re-exports both under their existing names, so no call site
// changed when this moved. Unlike the other two splits, this one is reached
// from a module base.leaf already loads on every page — inplace-forms.js calls
// refreshEditSurface() after every successful in-place save — so it is loaded
// there beside chickadee-ui.js rather than on the two workbench pages.
//
// `location.reload()` is the obvious way to pick up a server-side change,
// and on the merged workbench (#1266) it is destructive: the edit form and
// a live Pyodide kernel share one document, so reloading to show a renamed
// suite section costs a 10-30s kernel boot and any unsaved cells. That is
// the exact failure the merge exists to prevent, so the refresh re-renders
// the *edit half only*, by fetching this same URL and swapping that half's
// subtree.
//
// On the standalone `/edit` page there is no kernel and no `#wb-shell`, so
// it stays a plain reload — same behaviour as before.
//
// Scroll position is preserved across the swap, because every caller is
// re-rendering after a small edit — uploading one support file, renaming
// one section — and landing back at the top of a long assignment each time
// is its own kind of lost work.

(function (global) {
    'use strict';

    var EDIT_HALF_SELECTOR = '.wb-pane-edit';

    /// Re-execute the inline `<script>` blocks in a freshly swapped subtree.
    ///
    /// `innerHTML` never executes scripts, so without this the new markup is
    /// inert — no suite table, no editors. Only inline blocks are re-run:
    /// `src=` modules are already loaded and merely *define* the globals the
    /// inline blocks call, so re-fetching them would re-run their IIFEs and
    /// double-bind. The inline blocks bind nothing to `document`/`window`
    /// themselves; the two module-level listeners that do (suite-table's
    /// dragover and pageshow) carry their own once-per-document guards.
    /// Re-execute the inline scripts in a freshly swapped pane.
    ///
    /// CONTRACT, which this function had never had written down. A `<script>`
    /// inserted by parsing HTML does not run — that is a deliberate platform
    /// rule — so a pane swap has to re-create the elements to get their page
    /// wiring back. That makes this the one place in the frontend that turns
    /// markup into running code on purpose, and the boundary is therefore:
    ///
    ///   * `root` must be a fragment the SERVER rendered for this same-origin
    ///     page (what `swapHalf` fetched). Never call it on markup that came
    ///     from a user, a message body, or any other document.
    ///   * `[src]` scripts are excluded by the selector: a swap re-runs page
    ///     wiring, it does not re-fetch modules.
    ///   * a `type` other than `text/javascript` is DATA — the JSON seed
    ///     islands the authoring pages carry — and is left untouched, both
    ///     because re-running it is meaningless and because a re-created
    ///     element must keep its type to still be findable.
    ///
    /// It is internal on purpose: `swapHalf` is the only caller and the only
    /// context where the first rule can be guaranteed. Exporting it would make
    /// that guarantee someone else's to keep.
    function runInlineScripts(pane) {
        var scripts = pane.querySelectorAll('script:not([src])');
        Array.prototype.forEach.call(scripts, function (old) {
            // JSON seed blocks are data, not code — re-running them is
            // meaningless and `type` must be preserved for the ones that are.
            if (old.type && old.type !== 'text/javascript') return;
            var s = document.createElement('script');
            s.textContent = old.textContent;
            old.parentNode.replaceChild(s, old);
        });
    }

    var NOTEBOOK_HALF_SELECTOR = '.wb-notebook-body';

    /// Fetch `url` and swap one half's subtree from the response.
    ///
    /// Shared by both halves so the failure handling, the "am I even on the
    /// merged workbench" test, and the inline-script re-execution cannot drift
    /// between them.
    ///
    /// `opts.keepElement` names an element (by id) to carry across the swap
    /// rather than let `innerHTML` destroy. The notebook half needs this for
    /// `#jl-frame`: 34 closures in notebook.js capture that element, and a
    /// fresh one would leave every one of them on a detached node. Moving it
    /// does reload it — which a notebook switch wants, since the kernel belongs
    /// to whichever notebook is open.
    function swapHalf(selector, url, opts) {
        opts = opts || {};
        if (typeof document === 'undefined') return Promise.resolve(false);
        var half = document.querySelector(selector);
        // Not the merged workbench — the standalone editor. Reload as before.
        if (!half || !document.getElementById('wb-shell')) {
            global.location.reload();
            return Promise.resolve(true);
        }
        var scrollTop = half.scrollTop;
        var kept = opts.keepElement ? document.getElementById(opts.keepElement) : null;
        return fetch(url, {
            credentials: 'same-origin',
            headers: { 'X-Requested-With': 'fetch' }
        }).then(function (res) {
            if (!res.ok) throw new Error('refresh failed: ' + res.status);
            return res.text();
        }).then(function (html) {
            var doc = new DOMParser().parseFromString(html, 'text/html');
            var fresh = doc.querySelector(selector);
            if (!fresh) throw new Error('refresh failed: ' + selector + ' not in response');

            // Build the replacement as real nodes, NOT via `innerHTML`.
            //
            // `half.innerHTML = fresh.innerHTML` serializes to markup and
            // re-parses it, which silently defeats `keepElement`: the element
            // we meant to carry across would be written out as text and a brand
            // new one built from it, leaving every closure that captured the
            // original pointing at a detached node. Importing nodes preserves
            // object identity for the one element that needs it.
            var frag = document.createDocumentFragment();
            Array.prototype.slice.call(fresh.childNodes).forEach(function (n) {
                frag.appendChild(document.importNode(n, true));
            });

            if (kept) {
                var incoming = frag.querySelector('#' + opts.keepElement);
                if (!incoming) throw new Error('refresh failed: ' + opts.keepElement + ' not in response');
                // The incoming element's attributes are the whole point — they
                // name which notebook to open. Copy them onto ours, then put
                // ours where the new one would have gone.
                Array.prototype.forEach.call(incoming.attributes, function (a) {
                    if (a.name !== 'id') kept.setAttribute(a.name, a.value);
                });
                incoming.parentNode.replaceChild(kept, incoming);
            }

            half.textContent = '';
            half.appendChild(frag);
            runInlineScripts(half);
            half.scrollTop = scrollTop;
            return true;
        }).catch(function () {
            // A failed refresh must not leave a half-swapped page. Whatever
            // prompted it already happened server-side, so a full reload is
            // correct — it costs the kernel, but showing stale state is worse.
            global.location.reload();
            return false;
        });
    }

    /// Re-render the edit half in place after a write.
    ///
    /// `window.location.href`, not a stored URL: the merged page's own URL
    /// already names exactly what to re-render, including which notebook is
    /// open, so there is no second URL to keep in sync (and no DOM-sourced
    /// navigation target to validate).
    function refreshEditSurface() {
        return swapHalf(EDIT_HALF_SELECTOR, global.location.href);
    }

    /// Open a different notebook (file and/or view) without leaving the page.
    ///
    /// The kernel restarts regardless — it is bound to the open notebook — so
    /// what this buys is the *edit half*: it is not rebuilt, so its open
    /// editors and any metadata typed but not yet saved survive, where a
    /// navigation took them with it.
    ///
    /// **Known limitation: the edit half's scroll position is not preserved.**
    /// Emptying the notebook half reflows the grid, and while it is empty the
    /// edit half stops overflowing, which clamps its `scrollTop` to 0. Writing
    /// the old value back — synchronously or on the next frame — does not
    /// survive; something resets it again before the layout settles, and I did
    /// not isolate what. Called out rather than papered over: an author who
    /// switches notebooks lands back at the top of the edit half. Their *work*
    /// is intact, which is the property that matters, and this is strictly
    /// better than the navigation it replaces, which lost the work too.
    function refreshNotebookSurface(url) {
        return swapHalf(NOTEBOOK_HALF_SELECTOR, url, { keepElement: 'jl-frame' })
            .then(function (ok) {
                if (!ok) return false;
                // Re-read the new data-* attributes and re-mount. Absent on a
                // page with no notebook half, which is not an error.
                if (typeof global.chickadeeRemountNotebook === 'function') {
                    global.chickadeeRemountNotebook();
                }
                return true;
            });
    }

    // The sessionStorage round-trip that used to restore scroll after the
    // pane's `location.replace` is gone with the navigation itself: the swap
    // never unloads the document, so `refreshEditSurface` just reads
    // `half.scrollTop` before and writes it back after.

    global.ChickadeeSurfaceSwap = {
        refreshEditSurface: refreshEditSurface,
        refreshNotebookSurface: refreshNotebookSurface
    };

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the global above.
    if (typeof module === 'object' && module.exports) {
        module.exports = global.ChickadeeSurfaceSwap;
    }
})(typeof self !== 'undefined' ? self : this);
