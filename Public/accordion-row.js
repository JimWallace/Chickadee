// Public/accordion-row.js
//
// The one inline detail-row accordion: an editor that expands in a `<tr>`
// beneath the row being edited. Two editors use it — the suite table
// (suite-table.js) and the achievements editor (achievements-editor.js) — and
// it lives in one place so they animate and tear down identically.
//
// Split out of chickadee-ui.js, which had accumulated eighteen unrelated
// functions behind one name. This one is a widget with its own DOM contract
// and its own animation rules, not a shared utility in the sense that escaping
// a string is, and it was loaded on every page for the two that call it.
//
//   ChickadeeAccordion.CARET_HTML
//       the disclosure caret markup, so a row that opens an accordion draws
//       the same caret as every other one.
//
//   build({colspan})  -> { tr, host, saveBtn, cancelBtn, status, anim, inner }
//       the detail-row skeleton, NOT yet inserted. The caller inserts
//       `parts.tr` wherever it belongs — the two editors have different
//       placement rules — and mounts its editor into `parts.host`.
//
//   open(parts, parentRow) -> parts
//       animates the inserted row open (0fr -> 1fr) and marks `parentRow`
//       expanded; scrolls it into view. Pass parentRow = null when appending a
//       brand-new row that has no parent yet.
//
//   close(tr, opts) -> finishNow()
//       animates the row closed and removes it. The returned function
//       completes the teardown synchronously, which is what lets a new editor
//       open before the old one's animation has finished. `opts.immediate` (or
//       the user's reduced-motion setting) tears down synchronously to begin
//       with. `opts.onDone` runs once, just before removal, while the content
//       is still mounted — for editor-specific cleanup such as rescuing a
//       singleton editor body. `opts.parentRow` un-marks the parent row.
//
// The height animation is the single-row grid `grid-template-rows: 0fr -> 1fr`
// technique (see styles.css): it animates the editor's intrinsic height with no
// magic max-height, which matters because the family editor's height varies a
// lot.
//
// Two rules here exist because of engine behaviour rather than design:
//
//   * the open is a DOUBLE requestAnimationFrame, so the 0fr starting state
//     paints before the flip to 1fr. A single frame does not reliably start the
//     transition across engines, and a transition that never starts is a row
//     that never reveals its overflow.
//   * every animated path carries a TIMEOUT fallback, because `transitionend`
//     does not fire in a backgrounded tab or under a `display: none` ancestor.
//     Without it, `close` would leave the detail row in the table forever.
(function (global) {
    'use strict';

    var CARET_HTML = '<span class="accordion-caret" aria-hidden="true">'
        + '<svg class="icon" aria-hidden="true"><use href="#i-chevron-right"/></svg></span>';

    function prefersReducedMotion() {
        return !!(global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches);
    }

    function build(opts) {
        opts = opts || {};
        var tr = document.createElement('tr');
        tr.className = 'suite-detail-row';
        var td = document.createElement('td');
        td.setAttribute('colspan', String(opts.colspan || 4));
        var anim = document.createElement('div');
        anim.className = 'suite-detail-anim';
        var inner = document.createElement('div');
        inner.className = 'suite-detail-inner';
        var host = document.createElement('div');
        host.className = 'suite-detail-host';
        var actions = document.createElement('div');
        actions.className = 'suite-detail-actions';
        var saveBtn = document.createElement('button');
        saveBtn.type = 'button';
        saveBtn.className = 'btn btn-primary btn-compact';
        saveBtn.textContent = 'Save';
        var cancelBtn = document.createElement('button');
        cancelBtn.type = 'button';
        cancelBtn.className = 'btn btn-compact';
        cancelBtn.textContent = 'Cancel';
        var status = document.createElement('span');
        status.className = 'suite-detail-status card-meta';
        actions.appendChild(saveBtn);
        actions.appendChild(cancelBtn);
        actions.appendChild(status);
        inner.appendChild(host);
        inner.appendChild(actions);
        anim.appendChild(inner);
        td.appendChild(anim);
        tr.appendChild(td);
        return {
            tr: tr, host: host, saveBtn: saveBtn,
            cancelBtn: cancelBtn, status: status, anim: anim, inner: inner
        };
    }

    function open(parts, parentRow) {
        if (parentRow) parentRow.classList.add('suite-row-expanded');
        var anim = parts.anim;
        var inner = parts.inner;
        // The inner clips while the row is partly open (the CSS default). Once
        // fully open, reveal overflow so editor popovers/tooltips aren't clipped.
        function reveal() { if (inner) inner.style.overflow = 'visible'; }
        if (prefersReducedMotion() || !anim) {
            if (anim) anim.classList.add('is-open');
            reveal();
        } else {
            global.requestAnimationFrame(function () {
                global.requestAnimationFrame(function () { anim.classList.add('is-open'); });
            });
            var revealed = false;
            anim.addEventListener('transitionend', function (e) {
                if (e.propertyName === 'grid-template-rows' && !revealed) { revealed = true; reveal(); }
            });
            setTimeout(function () { if (!revealed) { revealed = true; reveal(); } }, 280);
        }
        if (parts.tr && parts.tr.scrollIntoView) parts.tr.scrollIntoView({ block: 'nearest' });
        return parts;
    }

    function close(tr, opts) {
        opts = opts || {};
        var parentRow = opts.parentRow || null;
        var done = false;
        function finish() {
            if (done) return;
            done = true;
            if (opts.onDone) { try { opts.onDone(); } catch (e) { /* the row still goes away */ } }
            if (tr && tr.parentNode) tr.parentNode.removeChild(tr);
            if (parentRow) parentRow.classList.remove('suite-row-expanded');
        }
        var anim = tr ? tr.querySelector('.suite-detail-anim') : null;
        if (opts.immediate || prefersReducedMotion() || !anim || !tr || !tr.parentNode) {
            finish();
            return finish;
        }
        // Re-clip before collapsing (open() set overflow:visible once expanded),
        // so content is clipped as the row shrinks rather than spilling out.
        var inner = tr.querySelector('.suite-detail-inner');
        if (inner) inner.style.overflow = 'hidden';
        anim.addEventListener('transitionend', function (e) {
            if (e.propertyName === 'grid-template-rows') finish();
        });
        setTimeout(finish, 320);
        anim.classList.remove('is-open');
        return finish;
    }

    global.ChickadeeAccordion = {
        CARET_HTML: CARET_HTML,
        build: build,
        open: open,
        close: close
    };

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the global above.
    if (typeof module === 'object' && module.exports) {
        module.exports = global.ChickadeeAccordion;
    }
})(typeof self !== 'undefined' ? self : this);
