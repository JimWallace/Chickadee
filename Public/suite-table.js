// Chickadee — Suite Table editor
//
// Client side of the assignment suite editor.  Owns ROW-level behaviour
// inside server-rendered section shells:
//   - renders each row into an existing <tbody data-section-id> (the
//     shell markup is emitted by `assignment-edit.leaf` from the
//     `suiteSectionRows` context)
//   - handles row drag within and across sections (cross-section drag
//     updates item.sectionID; clears dependsOn to avoid orphan parents;
//     debounced `PUT /suite` persists)
//   - handles tier / points / display-name inline edits on rows
//   - handles section rename toggle (.js-section-edit-toggle / -cancel),
//     section delete (JS confirm + dynamic form POST), and section
//     drag-reorder (AJAX `POST /suite-sections/reorder`)
//
// v0.4.98 refactor: section CRUD no longer runs through `PUT /suite`.
// `+ Section` is a `<details>` popup with a classic form POST to
// `/instructor/:id/suite-sections` (see AssignmentRoutes+SuiteSections.swift);
// the page reloads on section create / rename / delete.  That mirrors the
// instructor-dashboard course-section pattern and eliminates the v0.4.96
// fragility where adding a section name had to ride the whole-state
// save pipeline.
//
// DOM contract:
//   div#suite-sections                    — server-rendered shell container
//   div.section-block[data-section-id]    — one per section (named + Ungrouped)
//   div.section-header                    — named sections only (Ungrouped skips)
//   tbody[data-section-id]                — where JS writes rows
//   script#suite-state-seed               — JSON seed (same shape as GET /suite)
//   input#suite-files-input               — optional upload input
//   button#add-test-btn                   — Upload trigger
//
// Host wires the module via `window.initSuiteTable({...})`.

(function (global) {
    'use strict';

    // Where a blocking suite-editor error is shown: the editor's own container
    // when it is on the page, else the shared helper's fallback. Looked up per
    // call rather than captured, because the edit surface is re-rendered in
    // place (ChickadeeUI.refreshEditSurface) and a captured node goes stale.
    function suiteErrorHost() {
        return document.getElementById('suite-sections');
    }

    // ── Upload classification (folded in from the retired suite-list.js,
    // #1126 — that file was ~90% dead; only this classification survived) ──
    //
    // Decides whether an uploaded file looks like a test script (by
    // extension, or by shebang for extensionless files) and which tier the
    // new row should default to.  Pure; unit-tested from
    // Tests/BrowserRunnerJSTests/suite-table.test.mjs via the module export
    // at the bottom of this file.

    var SCRIPT_EXTS = ['sh','bash','zsh','py','r','rb','pl','js','php'];
    var BINARY_EXTS = ['exe','dll','so','dylib','class','jar','zip','tar','gz',
                       'png','jpg','jpeg','gif','bmp','svg','pdf','doc','docx',
                       'xls','xlsx','ppt','pptx','mp3','mp4','mov','avi'];

    function extensionOf(name) {
        var base = String(name || '').split('/').pop();
        var dot = base.lastIndexOf('.');
        return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
    }

    function isLikelyScriptName(name) {
        return SCRIPT_EXTS.indexOf(extensionOf(name)) >= 0;
    }

    function hasRecognizedScriptShebang(text) {
        var firstLine = String(text || '').split(/\r?\n/, 1)[0].trim().toLowerCase();
        if (firstLine.indexOf('#!') !== 0) return false;
        return /(^#!\s*\/.*\/(ba|z)?sh\b)|(^#!\s*\/usr\/bin\/env\s+(ba|z)?sh\b)|(^#!.*\bpython[0-9.]*\b)/.test(firstLine);
    }

    function classify(name, content, size) {
        var ext = extensionOf(name);
        var hasExt = ext.length > 0;
        var binary = BINARY_EXTS.indexOf(ext) >= 0;
        var scriptShebang = !hasExt && hasRecognizedScriptShebang(content || '');
        var isScript = isLikelyScriptName(name) || scriptShebang;
        var errs = [];
        if (binary) errs.push('Binary file — unlikely to work as a test script');
        if (!hasExt && !scriptShebang) {
            errs.push('No extension or recognized shebang; this file will be included as support unless marked as a test');
        }
        if (size === 0) errs.push('Empty file');
        return {
            isScript: isScript,
            tier: isScript ? 'public' : 'support',
            errors: errs
        };
    }

    function classifyFile(file) {
        if (!file) return Promise.resolve(classify('', '', 0));
        var ext = extensionOf(file.name);
        if (ext) return Promise.resolve(classify(file.name, '', file.size));
        var reader = typeof file.text === 'function'
            ? file.text()
            : Promise.resolve('');
        return reader
            .then(function (text) { return classify(file.name, text, file.size); })
            .catch(function () { return classify(file.name, '', file.size); });
    }

    // Module-level, deliberately outside initSuiteTable: these gate listeners
    // that live on `document`/`window` rather than on the swapped subtree, so
    // they must survive re-initialisation rather than be reset by it.
    var boundDocumentDragover = false;
    var boundPageshow = false;

    function initSuiteTable(config) {
        config = config || {};
        var csrfToken = config.csrfToken || '';
        var urls      = config.urls || {};
        var formSelector = config.formSelector || 'form.form';

        // `reorderSections` is required rather than derived. It used to be
        // computed from putSuite() by rewriting a trailing path segment, which
        // silently produced the wrong endpoint on the create page: that page's
        // putSuite() ends in a query string rather than the segment, so the
        // anchored rewrite never matched, and the reorder POSTed to the suite
        // endpoint — which is registered GET/PUT only. The 405 surfaced to the
        // instructor as "Section reorder failed". A missing builder must fail
        // loudly at init, not resolve to a URL that happens to exist.
        //
        // (The old pattern is asserted absent by section-reorder-url.test.mjs,
        // so it is described here rather than quoted.)
        if (typeof urls.putSuite !== 'function'
         || typeof urls.deleteScript !== 'function'
         || typeof urls.uploadScript !== 'function'
         || typeof urls.reorderSections !== 'function') {
            throw new Error('initSuiteTable: urls must supply putSuite, deleteScript, '
                + 'uploadScript, reorderSections functions');
        }

        var filesInput  = document.getElementById('suite-files-input');
        var container   = document.getElementById('suite-sections');
        var form        = document.querySelector(formSelector);
        if (!container) return noopAPI();

        var items    = [];
        var dragID        = null;   // row drag
        var dragSectionID = null;   // section header drag
        var pushTimer = null;
        var pushInFlight = false;
        var pushPending = false;
        // Resolvers awaiting "no push in flight or pending" — replaces the
        // old 50 ms setInterval spin in the form-submit path.
        var pushSettledWaiters = [];

        function whenPushSettled() {
            if (!pushInFlight && !pushPending) return Promise.resolve();
            return new Promise(function (resolve) { pushSettledWaiters.push(resolve); });
        }

        function notifyPushSettledIfIdle() {
            if (pushInFlight || pushPending) return;
            var waiters = pushSettledWaiters;
            pushSettledWaiters = [];
            waiters.forEach(function (resolve) { resolve(); });
        }

        // Seed from the server-rendered JSON blob — same shape as
        // `GET /suite`.  Section membership flows through items' sectionID;
        // the section shell list is server-rendered, not maintained here.
        (function seed() {
            var el = document.getElementById('suite-state-seed');
            if (!el) return;
            var payload;
            try { payload = JSON.parse(el.textContent || '{"items":[]}'); }
            catch (_) { payload = { items: [] }; }
            items = normaliseItems(payload.items || []);
        })();

        function currentSectionIDs() {
            return Array.from(container.querySelectorAll('.section-block[data-section-id]'))
                .map(function (b) { return b.getAttribute('data-section-id'); });
        }
        function sectionIDsInOrder() {
            return Array.from(container.querySelectorAll('.section-block[data-section-id]:not([data-ungrouped])'))
                .map(function (b) { return b.getAttribute('data-section-id'); })
                .filter(function (s) { return s; });
        }

        function normaliseItems(raw) {
            var validSectionIDs = {};
            currentSectionIDs().forEach(function (id) { validSectionIDs[id] = true; });
            return (raw || []).map(function (i) {
                var sid = i.sectionID != null ? String(i.sectionID) : null;
                if (sid && !validSectionIDs[sid]) sid = null;
                if (i.kind === 'family' && i.family) {
                    var fid = i.family.id;
                    return {
                        kind: 'family',
                        id: 'family:' + fid,
                        familyID: fid,
                        family: i.family,
                        dependsOn: (i.dependsOn && i.dependsOn.length)
                            ? i.dependsOn.slice()
                            : (i.family.dependsOn || []).slice(),
                        sectionID: sid
                    };
                }
                if (i.kind === 'check' && i.check) {
                    var cid = i.check.id;
                    return {
                        kind: 'check',
                        id: 'check:' + cid,
                        checkID: cid,
                        check: i.check,
                        // Read-only on the row; carried so re-PUTs include
                        // the full spec back.  The server only acts on
                        // (id, sectionID) for kind:"check", so mutations
                        // here are ignored on save — check fields belong
                        // in the notebook-check modal.
                        dependsOn: (i.check.dependsOn || []).slice(),
                        sectionID: sid
                    };
                }
                var s = i.script || {};
                return {
                    kind: 'script',
                    id: s.script || '',
                    script: s.script || '',
                    tier: s.tier || 'public',
                    points: Math.max(0, parseInt(s.points) || 0),
                    displayName: s.displayName == null ? '' : String(s.displayName),
                    dependsOn: (s.dependsOn || []).slice(),
                    sectionID: sid,
                    // Instructor hint (PR4a/PR4c). Carried on every item and
                    // re-emitted in buildPayload so a reorder/family-save push
                    // never wipes it (the server takes hint from the DTO).
                    hint: s.hint == null ? '' : String(s.hint),
                    // Per-test time-limit override (#979). Same carry-and-
                    // re-emit contract as hint: the server takes the DTO value
                    // unconditionally, so dropping it here would wipe an
                    // override on the next reorder. null = inherit the
                    // assignment default.
                    timeLimitSeconds: s.timeLimitSeconds != null
                        ? Math.max(1, parseInt(s.timeLimitSeconds) || 0) : null
                };
            });
        }

        // Shared implementations (Public/chickadee-ui.js); local aliases keep
        // the many call sites short.
        var escHtml = ChickadeeUI.escapeHtml;
        var escAttr = ChickadeeUI.escapeAttr;

        function findByID(id) { return items.find(function (it) { return it.id === id; }); }
        function itemsInSection(sid) {
            return items.filter(function (it) { return (it.sectionID || null) === (sid || null); });
        }
        function hasChildrenInSection(id, sid) {
            return items.some(function (it) {
                return (it.sectionID || null) === (sid || null) && it.dependsOn.indexOf(id) >= 0;
            });
        }
        function isChild(id) {
            var it = findByID(id);
            return it ? (it.dependsOn && it.dependsOn.length > 0) : false;
        }

        /// The whole connected dependency cluster reachable from `rootID`,
        /// walking edges in BOTH directions: an item's prerequisites (the ids
        /// in its `dependsOn`) and its dependents (items whose `dependsOn`
        /// names it).  Used when moving a test between sections so the entire
        /// group travels together instead of stranding dependents in the old
        /// section.  Because the closure includes every prerequisite and every
        /// dependent, all dependency edges of the returned set are internal —
        /// moving them as a block leaves no cross-section dangling links.
        /// Returns the member ids (order unspecified; callers preserve the
        /// existing `items[]` order, which is already topologically valid).
        function connectedDependencyGroup(rootID) {
            var byID = {};
            items.forEach(function (it) { byID[it.id] = it; });
            var seen = {};
            var stack = [rootID];
            while (stack.length) {
                var id = stack.pop();
                if (seen[id] || !byID[id]) continue;
                seen[id] = true;
                (byID[id].dependsOn || []).forEach(function (d) {
                    if (byID[d] && !seen[d]) stack.push(d);
                });
                items.forEach(function (other) {
                    if (!seen[other.id] && (other.dependsOn || []).indexOf(id) >= 0) {
                        stack.push(other.id);
                    }
                });
            }
            return Object.keys(seen);
        }

        function stemOf(filename) {
            var dot = filename.lastIndexOf('.');
            return dot > 0 ? filename.slice(0, dot) : filename;
        }

        /// Within-section visual tree: one-level parent/child indent keyed
        /// by `dependsOn[0]`.  Parents must be in the same section to
        /// indent — cross-section deps are allowed but don't render as
        /// visual parenting (the indent would span tables).
        function visualOrderForSection(sid) {
            var sectionItems = itemsInSection(sid);
            var byID = {};
            sectionItems.forEach(function (it) { byID[it.id] = it; });
            var childMap = {};
            sectionItems.forEach(function (it) {
                if (it.dependsOn && it.dependsOn.length > 0) {
                    var p = it.dependsOn[0];
                    if (byID[p]) {
                        childMap[p] = childMap[p] || [];
                        childMap[p].push(it);
                    }
                }
            });
            var result = [];
            sectionItems.filter(function (it) {
                if (!it.dependsOn || it.dependsOn.length === 0) return true;
                return !byID[it.dependsOn[0]];
            }).forEach(function (root) {
                result.push({ item: root, depth: 0 });
                (childMap[root.id] || []).forEach(function (child) {
                    result.push({ item: child, depth: 1 });
                });
            });
            return result;
        }

        function tierOptions(selected) {
            return ['support','public','secret','release'].map(function (t) {
                return '<option value="' + t + '"' + (t === selected ? ' selected' : '') + '>' + t + '</option>';
            }).join('');
        }

        // v0.4.105: dependency badge ("↳ test_detect_marker.py") removed
        // from the suite-table — the parent/child indent + connector
        // already conveys the relationship visually, and the trailing
        // filename text added clutter without information.  Function
        // kept as a no-op so callers don't need to change.
        function depBadgeHTML(_dependsOn) {
            return '';
        }

        function scriptRowHTML(item, depth) {
            var indent    = depth > 0 ? ' class="suite-child-indent"' : '';
            var connector = depth > 0 ? '<span class="suite-child-connector">&#9492;</span>' : '';
            var pts       = item.points || 1;
            var nameVal   = escAttr(item.displayName || stemOf(item.script));
            return '<tr data-id="' + escAttr(item.id) + '" data-kind="script" data-source="existing">'
                + '<td' + indent + '><div class="suite-name-cell">'
                +   '<span class="suite-drag-handle" draggable="true" title="Drag to reorder or adopt">⋮⋮</span>'
                +   connector
                +   '<input type="text" class="form-input cell-input suite-name-input js-suite-display-name" value="' + nameVal + '">'
                +   depBadgeHTML(item.dependsOn)
                + '</div></td>'
                + '<td><select class="form-input select-xs js-suite-tier">'
                +   tierOptions(item.tier)
                + '</select></td>'
                + '<td><input type="number" class="form-input cell-input points-input js-suite-points" min="0" max="100" value="' + pts + '"></td>'
                + '<td class="time"><div class="cell-actions">'
                +   '<button class="btn action-btn action-btn-icon js-suite-edit-btn" type="button" data-filename="' + escAttr(item.script) + '" title="Edit script" aria-label="Edit script"><svg class="icon" aria-hidden="true"><use href="#i-pencil"/></svg></button>'
                +   '<button class="btn action-btn action-btn-icon action-danger js-suite-delete-btn" type="button" title="Delete script" aria-label="Delete script"><svg class="icon" aria-hidden="true"><use href="#i-trash"/></svg></button>'
                + '</div></td>'
                + '</tr>';
        }

        function familyRowHTML(item, depth) {
            var indent    = depth > 0 ? ' class="suite-child-indent"' : '';
            var connector = depth > 0 ? '<span class="suite-child-connector">&#9492;</span>' : '';
            var family = item.family || {};
            var caseCount = (family.cases || []).filter(function (c) { return c.enabled !== false; }).length;
            var caseText  = caseCount === 1 ? '1 case' : caseCount + ' cases';
            var defaults = family.defaults || {};
            var defaultPoints = Math.max(0, parseInt(defaults.points) || 1);
            var tier = defaults.tier || 'public';
            return '<tr data-id="' + escAttr(item.id) + '" data-kind="family" data-source="family" data-family-id="' + escAttr(family.id || '') + '">'
                + '<td' + indent + '><div class="suite-name-cell">'
                +   '<span class="suite-drag-handle" draggable="true" title="Drag to reorder or adopt">⋮⋮</span>'
                +   connector
                +   '<div class="cell-stack">'
                +     '<strong class="cell-title">' + escHtml(family.name || family.id || '') + '</strong>'
                +     '<span class="card-meta hint-xs">' + caseText + '</span>'
                +   '</div>'
                + '</div></td>'
                + '<td><select class="form-input select-xs js-suite-family-tier">'
                +   ['public','secret','release'].map(function (t) {
                        return '<option value="' + t + '"' + (t === tier ? ' selected' : '') + '>' + t + '</option>';
                    }).join('')
                + '</select></td>'
                + '<td><input type="number" class="form-input cell-input points-input js-suite-family-points" min="0" max="100" value="' + defaultPoints + '" title="Points per case — applied to every generated test"></td>'
                + '<td class="time"><div class="cell-actions">'
                +   ChickadeeUI.accordion.CARET_HTML
                +   '<button class="btn action-btn action-btn-icon js-family-edit-btn" type="button" data-family-id="' + escAttr(family.id || '') + '" title="Edit family" aria-label="Edit family"><svg class="icon" aria-hidden="true"><use href="#i-pencil"/></svg></button>'
                +   '<button class="btn action-btn action-btn-icon action-danger js-family-delete-btn" type="button" data-family-id="' + escAttr(family.id || '') + '" title="Delete family" aria-label="Delete family"><svg class="icon" aria-hidden="true"><use href="#i-trash"/></svg></button>'
                + '</div></td>'
                + '</tr>';
        }

        function checkRowHTML(item, depth) {
            var indent    = depth > 0 ? ' class="suite-child-indent"' : '';
            var connector = depth > 0 ? '<span class="suite-child-connector">&#9492;</span>' : '';
            var check  = item.check || {};
            var label  = check.name || check.id || '';
            var kind   = check.kind || '';
            var tier   = check.tier  || 'public';
            var points = Math.max(0, parseInt(check.points) || 0);
            return '<tr data-id="' + escAttr(item.id) + '" data-kind="check" data-source="check" data-check-id="' + escAttr(check.id || '') + '">'
                + '<td' + indent + '><div class="suite-name-cell">'
                +   '<span class="suite-drag-handle" draggable="true" title="Drag to reorder">⋮⋮</span>'
                +   connector
                +   '<div class="cell-stack">'
                +     '<strong class="cell-title">' + escHtml(label) + '</strong>'
                +     '<span class="card-meta hint-xs">' + escHtml(kind || 'notebook check') + '</span>'
                +   '</div>'
                + '</div></td>'
                + '<td><select class="form-input select-xs js-suite-check-tier">'
                +   ['public','secret','release'].map(function (t) {
                        return '<option value="' + t + '"' + (t === tier ? ' selected' : '') + '>' + t + '</option>';
                    }).join('')
                + '</select></td>'
                + '<td><input type="number" class="form-input cell-input points-input js-suite-check-points" min="0" max="100" value="' + points + '"></td>'
                + '<td class="time"><div class="cell-actions">'
                +   ChickadeeUI.accordion.CARET_HTML
                +   '<button class="btn action-btn action-btn-icon js-check-edit-btn" type="button" data-check-id="' + escAttr(check.id || '') + '" title="Edit notebook check" aria-label="Edit notebook check"><svg class="icon" aria-hidden="true"><use href="#i-pencil"/></svg></button>'
                +   '<button class="btn action-btn action-btn-icon action-danger js-check-delete-btn" type="button" data-check-id="' + escAttr(check.id || '') + '" title="Delete notebook check" aria-label="Delete notebook check"><svg class="icon" aria-hidden="true"><use href="#i-trash"/></svg></button>'
                + '</div></td>'
                + '</tr>';
        }

        function rowHTML(item, depth) {
            if (item.kind === 'family') return familyRowHTML(item, depth);
            if (item.kind === 'check')  return checkRowHTML(item, depth);
            return scriptRowHTML(item, depth);
        }

        /// Preserves which script-row input (display-name, tier, points)
        /// was focused and where the caret sat, across the `innerHTML`
        /// rebuilds triggered by a debounced `PUT /suite` response.
        /// Section-name inputs don't need this any more — they live in
        /// server-rendered forms that don't get touched by `PUT /suite`.
        function captureFocus() {
            var el = document.activeElement;
            if (!el || !container.contains(el)) return null;
            var row = el.closest && el.closest('tr[data-id]');
            if (!row) return null;
            var cls = (el.className || '').split(/\s+/).filter(function (c) {
                return c && c.indexOf('form-') !== 0;
            })[0];
            if (!cls) return null;
            var start = null, end = null;
            try { start = el.selectionStart; end = el.selectionEnd; } catch (_) {}
            return { dataID: row.getAttribute('data-id'), cls: cls, start: start, end: end };
        }

        function restoreFocus(snap) {
            if (!snap) return;
            var row = container.querySelector('tr[data-id="' + cssAttrEscape(snap.dataID) + '"]');
            if (!row) return;
            var el = row.querySelector('.' + snap.cls);
            if (!el) return;
            el.focus();
            if (snap.start != null && snap.end != null) {
                try { el.setSelectionRange(snap.start, snap.end); } catch (_) {}
            }
        }

        // ── Inline editor (accordion) state ──
        // Only one inline editor is open at a time (the family/check renderers
        // are singletons). `renderSuspended` gates renderTree while it's open so
        // a debounced PUT response can't wipe the open detail row.
        var expandedDetail = null;   // { rowID, mechanism, renderer, detailRow }
        var lingeringClose = null;   // finishNow() of an in-flight animated collapse
        var renderSuspended = false;
        var renderPendingFlag = false;

        /// Escape a value for safe interpolation inside a double-quoted CSS
        /// attribute selector — backslash first, then double-quote (closes
        /// CodeQL js/incomplete-sanitization on the [data-*="…"] lookups).
        function cssAttrEscape(v) {
            return String(v == null ? '' : v).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
        }

        /// Write rows into every server-rendered tbody.  Items without a
        /// sectionID (or with a stale one) land in the Ungrouped tbody
        /// (data-section-id=""), which the server always renders when any
        /// item is ungrouped.
        function renderTree() {
            // While an inline editor (accordion) is open, defer re-rendering the
            // tbodies — an innerHTML rebuild would wipe the open detail row
            // mid-edit. The deferred render runs when the editor collapses.
            if (renderSuspended) { renderPendingFlag = true; return; }
            var focusSnap = captureFocus();
            var tbodies = container.querySelectorAll('tbody[data-section-id]');
            var bySection = {};
            tbodies.forEach(function (tb) {
                var sid = tb.getAttribute('data-section-id') || '';
                bySection[sid] = tb;
            });
            var ungroupedKey = '';
            Object.keys(bySection).forEach(function (sid) {
                var body = bySection[sid];
                var logical = sid || null;
                var visual = visualOrderForSection(logical);
                // An empty section's only drop target is this row, so label it
                // as a "move into" target; a populated section's row keeps the
                // "remove dependency" meaning (dropping a child here within its
                // own section promotes it to a top-level root).
                var rootLabel = visual.length
                    ? '&#9660; Drop here to remove dependency'
                    : '&#9660; Drop tests here';
                body.innerHTML = visual.map(function (v) { return rowHTML(v.item, v.depth); }).join('')
                    + '<tr class="suite-root-drop"><td colspan="4">' + rootLabel + '</td></tr>';
            });
            // Items whose sectionID doesn't resolve to any server-rendered
            // tbody (shouldn't happen given `normaliseItems` nils orphans,
            // but defensive) fall into Ungrouped.
            var ungroupedBody = bySection[ungroupedKey];
            if (ungroupedBody) {
                var orphans = items.filter(function (it) {
                    var sid = it.sectionID || '';
                    return !bySection[sid];
                });
                if (orphans.length) {
                    orphans.forEach(function (it) { it.sectionID = null; });
                }
            }
            restoreFocus(focusSnap);
        }

        // ── Inline editor (accordion) open/close ──

        /// ctx handed to a renderer hosted inline. Mirrors the modal's ctx so
        /// the same family/check renderers work in either host.
        function inlineCtx(sectionID) {
            return {
                csrfToken: csrfToken,
                getSectionID: function () { return sectionID || null; },
                setStatus: function () {},
                extractErrorMessage: extractErrorMessage
            };
        }

        /// Tear down the open inline editor: cleanup the renderer, remove the
        /// detail row, un-suspend renderTree, and flush any deferred render.
        /// Animates the collapse via the shared accordion helper unless
        /// `immediate` is set — programmatic callers (opening another editor,
        /// the modal) pass immediate so the singleton renderers and
        /// #family-editor-body are never shared by two live editors at once.
        function collapseInlineEditor(immediate) {
            var d = expandedDetail;
            // No open editor: still flush any collapse that's mid-animation so a
            // caller about to open a new editor starts from a clean slate.
            if (!d) {
                if (lingeringClose) { var f = lingeringClose; lingeringClose = null; f(); }
                return;
            }
            expandedDetail = null;
            var parentRow = d.rowID
                ? container.querySelector('tr[data-id="' + cssAttrEscape(d.rowID) + '"]')
                : null;
            // The actual teardown runs once, just before the row is removed —
            // while content is still mounted — so the family editor can rescue
            // its singleton #family-editor-body before the row goes away.
            function onTornDown() {
                lingeringClose = null;
                if (d.renderer && typeof d.renderer.cleanup === 'function') {
                    try { d.renderer.cleanup(); } catch (e) { /* ignore */ }
                }
                if (d.mechanism === 'family') {
                    var fb = document.getElementById('family-editor-body');
                    if (fb) {
                        fb.hidden = true;
                        fb.style.display = 'none';
                        document.body.appendChild(fb);
                    }
                }
                renderSuspended = false;
                if (renderPendingFlag) { renderPendingFlag = false; renderTree(); }
            }
            var finishNow = ChickadeeUI.accordion.close(d.detailRow, {
                immediate: !!immediate,
                parentRow: parentRow,
                onDone: onTornDown
            });
            lingeringClose = immediate ? null : finishNow;
        }

        /// Open an inline editor for a family/check — either editing an existing
        /// item (opts.editing.item + opts.afterRowID) or authoring a new one
        /// (opts.kind, appended to the section's tbody). Hosts the singleton
        /// renderer in a detail row with Save/Cancel; persistence flows through
        /// the renderer's persistAndSync (the same PUT /suite path the modal
        /// used). Custom scripts still use the modal.
        function expandInlineEditor(opts) {
            opts = opts || {};
            var renderer = (window.ChickadeeTestRenderers || {})[opts.mechanism];
            if (!renderer) { ChickadeeUI.showActionError('This test type is unavailable — reload the page.', suiteErrorHost()); return; }

            // Section: caller-supplied, else inherited from the edited item's row.
            var sectionID = (opts.sectionID != null) ? opts.sectionID : null;
            if (sectionID == null && opts.afterRowID) {
                var srcItem = findByID(opts.afterRowID);
                if (srcItem) sectionID = srcItem.sectionID || null;
            }

            // Toggle off when re-clicking the row that's already open (animated).
            if (opts.afterRowID && expandedDetail && expandedDetail.rowID === opts.afterRowID) {
                collapseInlineEditor();
                return;
            }
            // Close any other open editor synchronously: the family/check
            // renderers are singletons, so two live editors can't coexist.
            collapseInlineEditor(true);

            var parts = ChickadeeUI.accordion.build({ colspan: 4 });
            var tr = parts.tr;
            var host = parts.host;
            var saveBtn = parts.saveBtn;
            var cancelBtn = parts.cancelBtn;
            var status = parts.status;

            var parentRow = opts.afterRowID
                ? container.querySelector('tr[data-id="' + cssAttrEscape(opts.afterRowID) + '"]')
                : null;
            if (parentRow) {
                parentRow.parentNode.insertBefore(tr, parentRow.nextSibling);
            } else {
                var sidSel = cssAttrEscape(sectionID || '');
                var tb = container.querySelector('tbody[data-section-id="' + sidSel + '"]')
                    || container.querySelector('tbody[data-section-id=""]')
                    || container.querySelector('tbody');
                if (!tb) { ChickadeeUI.showActionError('No section to add this test to.', suiteErrorHost()); return; }
                var rootDrop = tb.querySelector('.suite-root-drop');
                if (rootDrop) tb.insertBefore(tr, rootDrop); else tb.appendChild(tr);
            }

            renderSuspended = true;
            window.__chickadeeTargetSection = sectionID || null;
            var ctx = inlineCtx(sectionID);
            expandedDetail = {
                rowID: opts.afterRowID || null,
                mechanism: opts.mechanism,
                renderer: renderer,
                detailRow: tr
            };

            try {
                renderer.mount(host, ctx);
                if (opts.editing && opts.editing.item) renderer.populate(opts.editing.item, ctx);
                else renderer.reset(opts.kind, ctx);
            } catch (e) {
                status.textContent = 'Could not open editor: ' + ((e && e.message) ? e.message : e);
            }

            saveBtn.addEventListener('click', function () {
                var spec;
                try { spec = renderer.readSpec(); }
                catch (err) {
                    status.textContent = (err && err.message) ? err.message : String(err);
                    status.classList.add('suite-detail-status-error');
                    return;
                }
                status.textContent = 'Saving…';
                status.classList.remove('suite-detail-status-error');
                saveBtn.disabled = true;
                renderer.persistAndSync(spec)
                    .then(function () { collapseInlineEditor(); })
                    .catch(function (err) {
                        status.textContent = 'Save failed — ' + ((err && err.message) ? err.message : err);
                        status.classList.add('suite-detail-status-error');
                        saveBtn.disabled = false;
                    });
            });
            cancelBtn.addEventListener('click', function () { collapseInlineEditor(false); });

            ChickadeeUI.accordion.open(parts, parentRow);
        }

        /// Entry point for the "+ Add Test" dropdown to author a NEW inline test
        /// (no parent row yet). Exposed as a window global so the Test Editor
        /// modal's dropdown can route family/check picks here.
        function addInlineTest(mechanism, kind, sectionID) {
            expandInlineEditor({ mechanism: mechanism, kind: kind, sectionID: sectionID || null, afterRowID: null });
        }
        window.chickadeeAddInlineTest = addInlineTest;
        // Edit an existing family/check inline (called by the family-edit button
        // in pattern-family-editor.js, and the check-edit button here).
        window.chickadeeExpandInlineEditor = expandInlineEditor;
        // Let the modal close any open inline editor before it opens, so the two
        // hosts never run simultaneously (the renderSuspended guard would
        // otherwise defer the modal's save render until the inline one closes).
        // Immediate (no animation) so the modal opens against a settled DOM.
        window.chickadeeCollapseInlineEditor = function () { collapseInlineEditor(true); };

        // ── Persistence (items only; sections go through dedicated endpoints) ──

        /// Linearize items[] into one contiguous run per sectionID, in the
        /// DOM section-block order.  The server enforces that items with
        /// the same sectionID form a contiguous block; mutation paths
        /// (root-drop, addExistingScript, reconcileFamilies) can otherwise
        /// leave items[] non-contiguous while the rendered tables still
        /// look correct (each <tbody> filters items[] by sectionID).
        function itemsGroupedBySection() {
            var blocks = container.querySelectorAll('.section-block[data-section-id]');
            var seen = new Set();
            var out = [];
            blocks.forEach(function (b) {
                var sid = b.getAttribute('data-section-id') || null;
                items.forEach(function (item) {
                    if ((item.sectionID || null) === (sid || null)) {
                        out.push(item);
                        seen.add(item);
                    }
                });
            });
            items.forEach(function (item) { if (!seen.has(item)) out.push(item); });
            return out;
        }

        function buildPayload() {
            return {
                items: itemsGroupedBySection().map(function (item) {
                    if (item.kind === 'family') {
                        var family = Object.assign({}, item.family);
                        family.dependsOn = item.dependsOn ? item.dependsOn.slice() : [];
                        return {
                            kind: 'family',
                            family: family,
                            dependsOn: family.dependsOn.slice(),
                            sectionID: item.sectionID || null
                        };
                    }
                    if (item.kind === 'check') {
                        // Server acts on (check.id, sectionID); the full
                        // spec is echoed so the response can re-emit the
                        // row without a separate /checks fetch.  Spec
                        // mutations route through PUT /checks (the modal).
                        return {
                            kind: 'check',
                            check: item.check,
                            sectionID: item.sectionID || null
                        };
                    }
                    var display = item.displayName && item.displayName.trim();
                    if (display === '' || display === stemOf(item.script)) display = null;
                    var scriptDTO = {
                        script:      item.script,
                        tier:        item.tier,
                        points:      Math.max(0, parseInt(item.points) || 0),
                        displayName: display,
                        dependsOn:   (item.dependsOn || []).slice(),
                        // Always send the current hint so reorders preserve it
                        // (the server takes hint from the DTO unconditionally).
                        hint:        (item.hint && item.hint.trim()) ? item.hint.trim() : null,
                        // Same contract for the per-test time-limit override.
                        timeLimitSeconds: item.timeLimitSeconds != null ? item.timeLimitSeconds : null
                    };
                    // Only send the body when a fresh edit staged it; omitting
                    // it leaves the existing file untouched (a reorder/retier
                    // need not resend the body). Cleared on re-seed after push.
                    if (item._content != null) scriptDTO.content = item._content;
                    return {
                        kind: 'script',
                        script: scriptDTO,
                        sectionID: item.sectionID || null
                    };
                })
            };
        }

        function schedulePush() {
            if (pushTimer) clearTimeout(pushTimer);
            pushTimer = setTimeout(doPush, 300);
        }

        /// Snapshot a row display-name input's live value so a debounced
        /// `PUT /suite` response doesn't wipe mid-typing text.
        function captureLiveEdit() {
            var el = document.activeElement;
            if (!el || !container.contains(el) || !el.classList) return null;
            if (el.classList.contains('js-suite-display-name')) {
                var row = el.closest('tr[data-kind="script"]');
                if (!row) return null;
                return {
                    itemID: row.getAttribute('data-id'),
                    value: el.value
                };
            }
            return null;
        }

        function applyLiveEdit(snap) {
            if (!snap) return;
            var it = findByID(snap.itemID);
            if (!it) return;
            var trimmed = (snap.value || '').trim();
            var newDisplay = (trimmed && trimmed !== stemOf(it.script)) ? trimmed : '';
            if ((it.displayName || '') !== newDisplay) {
                it.displayName = newDisplay;
                snap.changed = true;
            }
        }

        function doPush() {
            if (pushInFlight) { pushPending = true; return; }
            pushInFlight = true;
            global.ChickadeeUI.fetchJSON(urls.putSuite(), {
                method: 'PUT', csrfToken: csrfToken, body: buildPayload()
            })
            .then(function (payload) {
                var liveEdit = captureLiveEdit();
                items = normaliseItems(payload.items || []);
                applyLiveEdit(liveEdit);
                renderTree();
                if (liveEdit && liveEdit.changed) schedulePush();
            })
            .catch(function (err) {
                // Surface the error rather than silently reloading (which
                // would wipe the instructor's other unsaved mutations).
                console.error('Suite save failed:', err);
                var msg = (err && err.message) ? err.message : String(err);
                ChickadeeUI.showActionError('Suite save failed: ' + msg
                    + ' — your edit is still in the page, so try again, or reload to recover.', suiteErrorHost());
            })
            .finally(function () {
                pushInFlight = false;
                if (pushPending) { pushPending = false; doPush(); }
                notifyPushSettledIfIdle();
            });
        }

        // Shared implementation (Public/chickadee-ui.js, #1126) — this file
        // used to carry an HTML-scraping variant that diverged from the
        // JSON-parsing one in test-editor-modal.js; the shared extractor
        // handles both shapes.
        var extractErrorMessage = global.ChickadeeUI.extractErrorMessage;

        // ── Drag & drop: rows ──

        function clearDropIndicators() {
            container.querySelectorAll('.drop-before,.drop-after,.drop-adopt,.drop-hover,.section-drop-before,.section-drop-after').forEach(function (r) {
                r.classList.remove('drop-before','drop-after','drop-adopt','drop-hover','section-drop-before','section-drop-after');
            });
        }

        // ── Auto-scroll while dragging ──
        // HTML5 drag-and-drop doesn't scroll the page on its own, so a suite
        // list taller than one screen can't be reorganised across the fold
        // (e.g. dragging a freed test up to its proper section).  When the
        // pointer nears the top/bottom edge of the viewport during an active
        // drag, scroll the window — driven by a requestAnimationFrame loop
        // keyed off the latest pointer Y so the speed ramps with proximity.
        var autoScrollRAF = null;
        var autoScrollVel = 0;
        var AUTO_SCROLL_EDGE = 80;   // px from a viewport edge that triggers scrolling
        var AUTO_SCROLL_MAX  = 20;   // max px per frame, reached at the very edge

        function autoScrollStep() {
            if (!autoScrollVel || (!dragID && !dragSectionID)) {
                autoScrollRAF = null;
                return;
            }
            window.scrollBy(0, autoScrollVel);
            autoScrollRAF = window.requestAnimationFrame(autoScrollStep);
        }

        function updateAutoScroll(clientY) {
            var vh = window.innerHeight || document.documentElement.clientHeight;
            var vel = 0;
            if (clientY < AUTO_SCROLL_EDGE) {
                vel = -AUTO_SCROLL_MAX * (1 - clientY / AUTO_SCROLL_EDGE);
            } else if (clientY > vh - AUTO_SCROLL_EDGE) {
                vel = AUTO_SCROLL_MAX * (1 - (vh - clientY) / AUTO_SCROLL_EDGE);
            }
            autoScrollVel = vel;
            if (vel && autoScrollRAF == null) {
                autoScrollRAF = window.requestAnimationFrame(autoScrollStep);
            }
        }

        function stopAutoScroll() {
            autoScrollVel = 0;
            if (autoScrollRAF != null) {
                window.cancelAnimationFrame(autoScrollRAF);
                autoScrollRAF = null;
            }
        }

        // Document-level so the pointer can leave the suite container (into the
        // page header/footer) and still drive the scroll near the edges.  Only
        // acts while one of our drags is in flight; never calls preventDefault
        // so the container's own dragover keeps owning the drop indicators.
        //
        // Bound once per document, not once per init.  #1266 re-runs
        // `initSuiteTable` after every in-place write (the merged workbench
        // swaps the edit half's DOM instead of reloading, so the kernel in the
        // other half survives), and a document-level listener added on each of
        // those would accumulate one auto-scroll driver per save.
        if (!boundDocumentDragover) {
            boundDocumentDragover = true;
            document.addEventListener('dragover', function (e) {
                if (dragID || dragSectionID) updateAutoScroll(e.clientY);
            });
        }

        container.addEventListener('dragstart', function (e) {
            var t = e.target;
            if (!t || !t.closest) { e.preventDefault(); return; }
            var rowHandle = t.closest('.suite-drag-handle');
            if (rowHandle) {
                var row = rowHandle.closest('tr[data-id]');
                if (!row) { e.preventDefault(); return; }
                dragID = row.getAttribute('data-id');
                dragSectionID = null;
                e.dataTransfer.effectAllowed = 'move';
                try { e.dataTransfer.setData('text/plain', dragID); } catch (_) {}
                row.classList.add('suite-row-dragging');
                return;
            }
            var sectionHandle = t.closest('.section-drag-handle');
            var header = t.closest('.section-header');
            if (sectionHandle && header) {
                var block = header.closest('.section-block[data-section-id]');
                if (!block) { e.preventDefault(); return; }
                var sid = block.getAttribute('data-section-id');
                if (!sid) { e.preventDefault(); return; }
                dragSectionID = sid;
                dragID = null;
                e.dataTransfer.effectAllowed = 'move';
                try { e.dataTransfer.setData('text/plain', 'section:' + sid); } catch (_) {}
                block.classList.add('section-dragging');
                return;
            }
            e.preventDefault();
        });

        container.addEventListener('dragend', function () {
            dragID = null;
            dragSectionID = null;
            stopAutoScroll();
            container.querySelectorAll('.suite-row-dragging').forEach(function (r) { r.classList.remove('suite-row-dragging'); });
            container.querySelectorAll('.section-dragging').forEach(function (r) { r.classList.remove('section-dragging'); });
            clearDropIndicators();
        });

        container.addEventListener('dragover', function (e) {
            if (dragSectionID) {
                e.preventDefault();
                clearDropIndicators();
                var overBlock = e.target.closest && e.target.closest('.section-block[data-section-id]');
                if (!overBlock) return;
                var overSid = overBlock.getAttribute('data-section-id');
                if (!overSid || overSid === dragSectionID) return;
                var brect = overBlock.getBoundingClientRect();
                var afterBlock = e.clientY > brect.top + brect.height / 2;
                overBlock.classList.add(afterBlock ? 'section-drop-after' : 'section-drop-before');
                return;
            }
            if (!dragID) return;
            e.preventDefault();
            clearDropIndicators();
            var rootZone = e.target.closest && e.target.closest('.suite-root-drop');
            if (rootZone) { rootZone.classList.add('drop-hover'); return; }
            var target = e.target.closest && e.target.closest('tr[data-id]');
            if (!target) return;
            var tid = target.getAttribute('data-id');
            if (tid === dragID) return;
            var tbody = target.closest('tbody[data-section-id]');
            var dragItem = findByID(dragID);
            var targetSid = tbody ? (tbody.getAttribute('data-section-id') || null) : null;
            var sameSection = dragItem && ((dragItem.sectionID || '') === (targetSid || ''));
            var rect  = target.getBoundingClientRect();
            var relY  = (e.clientY - rect.top) / rect.height;
            // Adopt onto a check row would produce a `check:<id>` dep
            // token, which the server doesn't expand — checks are always
            // leaf nodes in the dependency graph for v0.4.x.
            var targetItem = findByID(tid);
            var targetIsCheck = targetItem && targetItem.kind === 'check';
            var dragItemHover = findByID(dragID);
            var dragIsCheck = dragItemHover && dragItemHover.kind === 'check';
            if (relY < 0.3) {
                target.classList.add('drop-before');
            } else if (relY > 0.7) {
                target.classList.add('drop-after');
            } else if (sameSection && !isChild(tid) && !hasChildrenInSection(dragID, targetSid)
                       && !targetIsCheck && !dragIsCheck) {
                target.classList.add('drop-adopt');
            } else {
                target.classList.add(relY < 0.5 ? 'drop-before' : 'drop-after');
            }
        });

        container.addEventListener('dragleave', function (e) {
            var row = e.target.closest && e.target.closest('tr');
            if (row) row.classList.remove('drop-before','drop-after','drop-adopt','drop-hover');
            var block = e.target.closest && e.target.closest('.section-block');
            if (block) block.classList.remove('section-drop-before','section-drop-after');
        });

        container.addEventListener('drop', function (e) {
            e.preventDefault();
            stopAutoScroll();
            // Section-drag: reorder server-rendered sections via AJAX.
            // On 200, update DOM order (we already did client-side) and
            // persist via a POST to /suite-sections/reorder.  No reload —
            // the dashboard pattern doesn't reload on reorder either.
            if (dragSectionID) {
                var overBlock = e.target.closest && e.target.closest('.section-block[data-section-id]');
                if (!overBlock) return;
                var overSid = overBlock.getAttribute('data-section-id');
                if (!overSid || overSid === dragSectionID) return;
                var draggedBlock = container.querySelector('.section-block[data-section-id="' + cssAttrEscape(dragSectionID) + '"]');
                if (!draggedBlock) return;
                var brect = overBlock.getBoundingClientRect();
                var afterBlock = e.clientY > brect.top + brect.height / 2;
                container.insertBefore(draggedBlock, afterBlock ? overBlock.nextSibling : overBlock);
                persistSectionOrder();
                return;
            }
            if (!dragID) return;
            var dragItem = findByID(dragID);
            if (!dragItem) return;

            var rootZone = e.target.closest && e.target.closest('.suite-root-drop');
            if (rootZone) {
                var tbody = rootZone.closest('tbody[data-section-id]');
                var newSid = tbody ? (tbody.getAttribute('data-section-id') || null) : null;
                var curSid = dragItem.sectionID || null;
                if ((newSid || null) === curSid) {
                    // Same section: this zone promotes the item to a top-level
                    // root by removing its dependency.
                    dragItem.dependsOn = [];
                } else {
                    // Different section (e.g. a freshly created, empty
                    // section whose only drop target is this row): move the
                    // whole connected dependency group so dependents and
                    // prerequisites travel together instead of being
                    // stranded.  Deps are preserved — the group is
                    // internally closed — and it lands as a contiguous block
                    // at the end of the target section.
                    let groupSet = {};
                    connectedDependencyGroup(dragID).forEach(function (id) { groupSet[id] = true; });
                    let moving = items.filter(function (it) { return groupSet[it.id]; });
                    moving.forEach(function (it) { it.sectionID = newSid || null; });
                    items = items.filter(function (it) { return !groupSet[it.id]; });
                    var lastIdx = -1;
                    items.forEach(function (it, idx) {
                        if ((it.sectionID || null) === (newSid || null)) lastIdx = idx;
                    });
                    if (lastIdx < 0) {
                        items = items.concat(moving);
                    } else {
                        items.splice.apply(items, [lastIdx + 1, 0].concat(moving));
                    }
                }
                renderTree(); schedulePush(); return;
            }

            var target = e.target.closest && e.target.closest('tr[data-id]');
            if (!target) return;
            var tid = target.getAttribute('data-id');
            if (!tid || tid === dragID) return;

            var tbodyEl = target.closest('tbody[data-section-id]');
            var targetSid = tbodyEl ? (tbodyEl.getAttribute('data-section-id') || null) : null;
            var sameSection = (dragItem.sectionID || '') === (targetSid || '');

            var rect = target.getBoundingClientRect();
            var relY = (e.clientY - rect.top) / rect.height;

            var dropTargetItem = findByID(tid);
            var dropTargetIsCheck = dropTargetItem && dropTargetItem.kind === 'check';
            var dropDragIsCheck = dragItem.kind === 'check';
            if (sameSection && relY >= 0.3 && relY <= 0.7 && !isChild(tid) && !hasChildrenInSection(dragID, targetSid)
                && !dropTargetIsCheck && !dropDragIsCheck) {
                dragItem.dependsOn = [tid];
                items = items.filter(function (it) { return it.id !== dragID; });
                var aIdx = items.findIndex(function (it) { return it.id === tid; });
                items.splice(aIdx + 1, 0, dragItem);
            } else if (!sameSection) {
                // Cross-section move: carry the whole connected dependency
                // group so dependents/prerequisites aren't stranded in the old
                // section.  Preserve each member's dependsOn (don't wipe the
                // links) and keep their existing relative order — already
                // topologically valid — as a contiguous block in the target
                // section.
                let groupSet = {};
                connectedDependencyGroup(dragID).forEach(function (id) { groupSet[id] = true; });
                let moving = items.filter(function (it) { return groupSet[it.id]; });
                moving.forEach(function (it) { it.sectionID = targetSid || null; });
                items = items.filter(function (it) { return !groupSet[it.id]; });
                var gIdx = items.findIndex(function (it) { return it.id === tid; });
                if (gIdx < 0) {
                    items = items.concat(moving);
                } else {
                    var insertAt = relY <= 0.5 ? gIdx : gIdx + 1;
                    items.splice.apply(items, [insertAt, 0].concat(moving));
                }
            } else {
                dragItem.dependsOn = [];
                items = items.filter(function (it) { return it.id !== dragID; });
                var tIdx = items.findIndex(function (it) { return it.id === tid; });
                items.splice(relY <= 0.5 ? tIdx : tIdx + 1, 0, dragItem);
            }
            renderTree(); schedulePush();
        });

        /// Persist the current DOM section order to the server via the
        /// dedicated reorder endpoint.  No page reload — the dashboard
        /// pattern returns 200 and trusts the client to have the right
        /// DOM state already.
        function persistSectionOrder() {
            var ids = sectionIDsInOrder();
            global.ChickadeeUI.fetchJSON(urls.reorderSections(), {
                method: 'POST', csrfToken: csrfToken, body: { sectionIDs: ids }
            })
            .catch(function (err) {
                console.error('Section reorder failed:', err);
                ChickadeeUI.showActionError('Section reorder failed: ' + (err.message || err) + ' — reload the page to recover.', suiteErrorHost());
            });
        }

        // ── Inline row edits ──

        container.addEventListener('change', function (e) {
            var scriptRow = e.target.closest && e.target.closest('tr[data-kind="script"]');
            if (scriptRow) {
                var item = findByID(scriptRow.getAttribute('data-id'));
                if (!item) return;
                var tierEl = scriptRow.querySelector('.js-suite-tier');
                var ptsEl  = scriptRow.querySelector('.js-suite-points');
                if (tierEl) item.tier = tierEl.value;
                if (ptsEl)  item.points = Math.max(0, parseInt(ptsEl.value) || 0);
                schedulePush();
                return;
            }
            var familyRow = e.target.closest && e.target.closest('tr[data-kind="family"]');
            if (familyRow) {
                var fitem = findByID(familyRow.getAttribute('data-id'));
                if (!fitem || !fitem.family) return;
                var tierElF = familyRow.querySelector('.js-suite-family-tier');
                var ptsElF  = familyRow.querySelector('.js-suite-family-points');
                var nextDefaults = Object.assign({}, fitem.family.defaults || {});
                if (tierElF) nextDefaults.tier = tierElF.value;
                if (ptsElF)  nextDefaults.points = Math.max(0, parseInt(ptsElF.value) || 0);
                fitem.family = Object.assign({}, fitem.family, { defaults: nextDefaults });
                schedulePush();
                return;
            }
            var checkRow = e.target.closest && e.target.closest('tr[data-kind="check"]');
            if (checkRow) {
                var citem = findByID(checkRow.getAttribute('data-id'));
                if (!citem || !citem.check) return;
                var tierElC = checkRow.querySelector('.js-suite-check-tier');
                var ptsElC  = checkRow.querySelector('.js-suite-check-points');
                var nextCheck = Object.assign({}, citem.check);
                if (tierElC) nextCheck.tier = tierElC.value;
                if (ptsElC)  nextCheck.points = Math.max(0, parseInt(ptsElC.value) || 0);
                citem.check = nextCheck;
                schedulePush();
            }
        });

        container.addEventListener('input', function (e) {
            var target = e.target;
            if (!target || !target.classList || !target.classList.contains('js-suite-display-name')) return;
            var row = target.closest('tr[data-kind="script"]');
            if (!row) return;
            var item = findByID(row.getAttribute('data-id'));
            if (!item) return;
            var val = target.value.trim();
            item.displayName = (val && val !== stemOf(item.script)) ? val : '';
        });

        container.addEventListener('change', function (e) {
            var target = e.target;
            if (!target || !target.classList || !target.classList.contains('js-suite-display-name')) return;
            schedulePush();
        });

        // Notebook-check row Edit/Delete (family edit/delete is handled by
        // pattern-family-editor.js).  Edit opens the unified Test Editor modal
        // pre-populated; Delete drops the check and re-saves the list via the
        // single PUT /suite write path.
        container.addEventListener('click', async function (e) {
            var editBtn = e.target.closest && e.target.closest('.js-check-edit-btn');
            if (editBtn) {
                let row = editBtn.closest('tr[data-kind="check"]');
                if (!row) return;
                var cid = row.getAttribute('data-check-id');
                let item = findByID('check:' + cid);
                if (!item) return;
                expandInlineEditor({
                    mechanism: 'check',
                    editing: { item: item.check },
                    sectionID: item.sectionID || null,
                    afterRowID: item.id
                });
                return;
            }
            var delBtn = e.target.closest && e.target.closest('.js-check-delete-btn');
            if (delBtn) {
                var row2 = delBtn.closest('tr[data-kind="check"]');
                if (!row2) return;
                var cid2 = row2.getAttribute('data-check-id');
                var item2 = findByID('check:' + cid2);
                if (!item2) return;
                var label = (item2.check && (item2.check.name || item2.check.id)) || cid2;
                if (!await ChickadeeUI.confirmAction('Delete notebook check "' + label + '"? This removes the generated test script.')) {
                    return;
                }
                var remaining = items
                    .filter(function (it) { return it.kind === 'check' && it.checkID !== cid2; })
                    .map(function (it) { return it.check; });
                saveChecksViaSuite(remaining)
                    .catch(function (err) { ChickadeeUI.showActionError('Could not delete check: ' + (err.message || err), suiteErrorHost()); });
                return;
            }

            var btn = e.target.closest && e.target.closest('.js-suite-delete-btn');
            if (!btn) return;
            var row = btn.closest('tr[data-kind="script"]');
            if (!row) return;
            var id = row.getAttribute('data-id');
            var item = findByID(id);
            if (!item) return;
            if (!await ChickadeeUI.confirmAction('Delete test script "' + item.script + '"? This also removes it as a dependency from other items.')) return;

            global.ChickadeeUI.fetchJSON(urls.deleteScript(item.script), {
                method: 'DELETE', csrfToken: csrfToken
            })
            .then(function () {
                items = items.filter(function (it) { return it.id !== id; });
                items.forEach(function (it) {
                    it.dependsOn = (it.dependsOn || []).filter(function (d) { return d !== id; });
                });
                renderTree();
                schedulePush();
            })
            .catch(function (err) {
                ChickadeeUI.showActionError('Could not delete: ' + (err.message || err), suiteErrorHost());
            });
        });

        // ── Section-header inline edit (rename toggle + delete) ──

        container.addEventListener('click', async function (e) {
            var toggle = e.target.closest && e.target.closest('.js-section-edit-toggle');
            if (toggle) {
                var header = toggle.closest('.section-header');
                if (!header) return;
                var view = header.querySelector('.section-view');
                var edit = header.querySelector('.section-edit');
                if (view) view.style.display = 'none';
                if (edit) {
                    edit.style.display = 'flex';
                    var inp = edit.querySelector('.section-name-input');
                    if (inp) { inp.focus(); inp.select(); }
                }
                return;
            }
            var cancel = e.target.closest && e.target.closest('.js-section-edit-cancel');
            if (cancel) {
                var header2 = cancel.closest('.section-header');
                if (!header2) return;
                var view2 = header2.querySelector('.section-view');
                var edit2 = header2.querySelector('.section-edit');
                if (view2) view2.style.display = 'flex';
                if (edit2) edit2.style.display = 'none';
                return;
            }
            var del = e.target.closest && e.target.closest('.js-section-delete-btn');
            if (del) {
                var action = del.getAttribute('data-action');
                var name = del.getAttribute('data-name') || 'this section';
                var bodySid = del.closest('.section-block[data-section-id]');
                var sid = bodySid ? bodySid.getAttribute('data-section-id') : '';
                var affected = items.filter(function (it) { return it.sectionID === sid; }).length;
                var msg = affected === 0
                    ? 'Delete section "' + name + '"?'
                    : 'Delete section "' + name + '"? Its ' + affected + ' test'
                      + (affected === 1 ? '' : 's') + ' will move to Ungrouped.';
                if (!await ChickadeeUI.confirmAction(msg)) return;
                var f = document.createElement('form');
                f.method = 'POST';
                f.action = action;
                // Marked and submitted the same way the template's own section
                // forms are, so that inside a workbench pane `inplace-forms.js`
                // intercepts this too.  `requestSubmit()` rather than
                // `submit()`: `submit()` deliberately skips submit listeners,
                // which would send the pane to the chromed standalone editor —
                // the same trap v0.4.133 hit with the multipart CSRF intercept.
                f.setAttribute('data-ck-inplace', '');
                var t = document.createElement('input');
                t.type = 'hidden'; t.name = '_csrf'; t.value = csrfToken;
                f.appendChild(t);
                document.body.appendChild(f);
                if (typeof f.requestSubmit === 'function') f.requestSubmit();
                else f.submit();
            }
        });

        // ── Upload + file input ──

        if (filesInput) {
            filesInput.addEventListener('change', function () {
                var files = Array.from(filesInput.files || []);
                filesInput.value = '';
                var chain = Promise.resolve();
                files.forEach(function (file) {
                    chain = chain.then(function () {
                        return classifyFile(file).then(function (cls) {
                            return file.text().then(function (content) {
                                return global.ChickadeeUI.fetchJSON(urls.uploadScript(), {
                                    method: 'POST', csrfToken: csrfToken,
                                    body: {
                                        filename: file.name,
                                        content: content,
                                        tier: cls.tier,
                                        points: 1,
                                        isTest: cls.isScript
                                    }
                                }).then(function (data) {
                                    addExistingScript(data);
                                });
                            });
                        });
                    });
                });
                chain.catch(function (err) { ChickadeeUI.showActionError('Upload failed: ' + (err.message || err), suiteErrorHost()); });
            });
        }

        var addTestBtn = document.getElementById('add-test-btn');
        if (addTestBtn && filesInput) {
            addTestBtn.addEventListener('click', function () {
                filesInput.click();
            });
        }

        // Flush any pending suite-state push AND any pending
        // section-vars auto-saves before letting the multipart form
        // submit.  v0.4.101: also awaits `window.chickadeeFlushSectionVars`
        // (wired by assignment-edit.leaf's section-vars IIFE) so the
        // main "Save & Validate" button also persists any shared-inputs
        // edits the instructor had in progress.
        //
        // v0.4.133: re-submit via `form.requestSubmit()` (NOT
        // `form.submit()`).  `form.submit()` deliberately bypasses
        // submit-event listeners — including base.leaf's multipart-CSRF
        // intercept that adds `x-csrf-token` to the request headers.
        // Without that header, the multipart body's `_csrf` field is
        // unreachable to the CSRF middleware (the body isn't buffered
        // before middleware runs), and every save 403s with
        // "No CSRF token provided".  `requestSubmit()` fires submit
        // events properly; the `__chickadeeFlushed` flag prevents this
        // listener from looping when the re-fired event arrives.
        if (form) {
            form.addEventListener('submit', function (e) {
                if (pushTimer) { clearTimeout(pushTimer); pushTimer = null; }

                // Second pass: the flushes are done and we requested a
                // re-submit.  Skip our handler so base.leaf's listener
                // can intercept the (now-clean) multipart submit.
                if (form.__chickadeeFlushed) {
                    form.__chickadeeFlushed = false;
                    return;
                }

                var sectionVarsPromise = (typeof window.chickadeeFlushSectionVars === 'function')
                    ? window.chickadeeFlushSectionVars()
                    : Promise.resolve();

                function resubmit() {
                    form.__chickadeeFlushed = true;
                    // Preserve any activating submit button so its
                    // `formaction` (e.g. hidden draft-action buttons on
                    // the create page) is honored on the re-fire.
                    if (typeof form.requestSubmit === 'function') {
                        form.requestSubmit(e.submitter || null);
                    } else {
                        // Fallback for ancient browsers without
                        // requestSubmit — dispatch a synthesized submit
                        // event so base.leaf's listener still fires.
                        form.dispatchEvent(new Event('submit', { cancelable: true, bubbles: true }));
                    }
                }

                if (pushInFlight || pushPending) {
                    e.preventDefault();
                    whenPushSettled().then(function () {
                        sectionVarsPromise.finally(resubmit);
                    });
                } else {
                    // No suite PUT pending — still wait for section-vars
                    // if they're in flight, since they might have been
                    // triggered by the same keystroke that led here.
                    e.preventDefault();
                    sectionVarsPromise.finally(resubmit);
                }
            });
        }

        /// Adds a newly-created script to the local items list and
        /// pushes.  v0.4.102: reads `window.__chickadeeTargetSection`
        /// set by per-section "+ New Script" / "Upload" delegators and
        /// stamps the new item's `sectionID`, so the new script lands
        /// in the section the instructor clicked from.  Unset falls
        /// back to ungrouped (global-toolbar behaviour).
        function addExistingScript(script) {
            if (!script || !script.filename) return;
            var target = window.__chickadeeTargetSection;
            var targetSid = (typeof target === 'string' && target) ? target : null;
            items = items.filter(function (it) {
                return !(it.kind === 'script' && it.script === script.filename);
            });
            items.push({
                kind: 'script',
                id: script.filename,
                script: script.filename,
                tier: script.tier || (script.isTest ? 'public' : 'support'),
                points: Math.max(0, parseInt(script.points) || 1),
                displayName: '',
                dependsOn: [],
                sectionID: targetSid
            });
            renderTree();
            schedulePush();
        }

        /// Reconciles `items` with a full family list: replace each family's
        /// spec, drop families no longer present, place newcomers in the
        /// clicked section, and prune dangling `family:` deps. Pure state
        /// mutation — no render/push, so callers pick how to persist.
        function reconcileFamilies(nextFamilies) {
            var byID = {};
            (nextFamilies || []).forEach(function (f) { byID[f.id] = f; });

            var seen = {};
            items = items.map(function (item) {
                if (item.kind !== 'family') return item;
                var f = byID[item.familyID];
                if (!f) return null;
                seen[item.familyID] = true;
                return {
                    kind: 'family',
                    id: 'family:' + f.id,
                    familyID: f.id,
                    family: f,
                    dependsOn: (f.dependsOn || []).slice(),
                    sectionID: item.sectionID || null
                };
            }).filter(Boolean);

            // v0.4.102: newcomer families land in the section the
            // instructor clicked "+ Add Test" from (if any); existing
            // families keep their current section via the map above.
            var target = window.__chickadeeTargetSection;
            var targetSid = (typeof target === 'string' && target) ? target : null;
            (nextFamilies || []).forEach(function (f) {
                if (seen[f.id]) return;
                items.push({
                    kind: 'family',
                    id: 'family:' + f.id,
                    familyID: f.id,
                    family: f,
                    dependsOn: (f.dependsOn || []).slice(),
                    sectionID: targetSid
                });
            });

            var aliveFamilyIDs = Object.keys(byID);
            items.forEach(function (it) {
                it.dependsOn = (it.dependsOn || []).filter(function (d) {
                    if (d.indexOf('family:') !== 0) return true;
                    var fid = d.slice('family:'.length);
                    return aliveFamilyIDs.indexOf(fid) >= 0;
                });
            });
        }

        /// Notebook-check mirror of reconcileFamilies.
        function reconcileChecks(nextChecks) {
            var byID = {};
            (nextChecks || []).forEach(function (c) { byID[c.id] = c; });

            var seen = {};
            items = items.map(function (item) {
                if (item.kind !== 'check') return item;
                var c = byID[item.checkID];
                if (!c) return null;
                seen[item.checkID] = true;
                return {
                    kind: 'check',
                    id: 'check:' + c.id,
                    checkID: c.id,
                    check: c,
                    dependsOn: (c.dependsOn || []).slice(),
                    sectionID: item.sectionID || null
                };
            }).filter(Boolean);

            // Newcomer checks land in the section the instructor clicked
            // "+ Add Test" from (if any); existing checks keep their section.
            var target = window.__chickadeeTargetSection;
            var targetSid = (typeof target === 'string' && target) ? target : null;
            (nextChecks || []).forEach(function (c) {
                if (seen[c.id]) return;
                items.push({
                    kind: 'check',
                    id: 'check:' + c.id,
                    checkID: c.id,
                    check: c,
                    dependsOn: (c.dependsOn || []).slice(),
                    sectionID: targetSid
                });
            });
        }

        /// Immediate (non-debounced) PUT /suite that re-seeds `items` from the
        /// reconciled response. Resolves with the response payload; rejects on
        /// HTTP error so the caller can restore optimistic state and surface
        /// the message.
        function pushSuiteNow() {
            return global.ChickadeeUI.fetchJSON(urls.putSuite(), {
                method: 'PUT', csrfToken: csrfToken, body: buildPayload()
            })
            .then(function (payload) {
                items = normaliseItems(payload.items || []);
                renderTree();
                return payload;
            });
        }

        function familiesFromPayload(payload) {
            return (payload.items || [])
                .filter(function (i) { return i.kind === 'family' && i.family; })
                .map(function (i) { return i.family; });
        }
        function checksFromPayload(payload) {
            return (payload.items || [])
                .filter(function (i) { return i.kind === 'check' && i.check; })
                .map(function (i) { return i.check; });
        }

        /// Phase 2a: persist a full family list through the single PUT /suite
        /// write path, replacing the pre-2a `PUT /families` + follow-up
        /// `PUT /suite` double-write. Optimistically reconciles, awaits the
        /// PUT (so the modal gets synchronous validation feedback), and on
        /// failure restores the prior state. Resolves with the applied family
        /// list; rejects with the server error.
        function saveFamiliesViaSuite(nextFamilies) {
            var snapshot = items.slice();
            reconcileFamilies(nextFamilies);
            renderTree();
            return pushSuiteNow()
                .then(function (payload) { return familiesFromPayload(payload); })
                .catch(function (err) { items = snapshot; renderTree(); throw err; });
        }

        /// Notebook-check mirror of saveFamiliesViaSuite.
        function saveChecksViaSuite(nextChecks) {
            var snapshot = items.slice();
            reconcileChecks(nextChecks);
            renderTree();
            return pushSuiteNow()
                .then(function (payload) { return checksFromPayload(payload); })
                .catch(function (err) { items = snapshot; renderTree(); throw err; });
        }

        /// PR4c: persist a hand-written script (create or content/hint edit)
        /// through the single `PUT /suite` write path, replacing the legacy
        /// `POST /scripts` / `PUT /scripts/:name` endpoints in the script
        /// editor. `spec` = { filename, content, hint, timeLimitSeconds?,
        /// tier?, points?, isTest? } (timeLimitSeconds: int, or null to
        /// inherit the assignment default; omit the key to leave unchanged).
        /// The body rides on a transient `_content` that buildPayload emits and
        /// the post-push re-seed drops; `hint` persists via the DTO. New scripts
        /// land in the clicked section; an existing script keeps its tier /
        /// points / displayName / deps / section unless `spec` overrides them.
        /// Resolves with the applied script DTO; rejects with the server error.
        function saveScriptViaSuite(spec) {
            spec = spec || {};
            if (!spec.filename) return Promise.reject(new Error('Script filename is required.'));
            var snapshot = items.slice();
            var existing = items.find(function (it) {
                return it.kind === 'script' && it.script === spec.filename;
            });
            if (existing) {
                if (spec.content != null) existing._content = spec.content;
                existing.hint = spec.hint || '';
                if (spec.timeLimitSeconds !== undefined) {
                    existing.timeLimitSeconds = spec.timeLimitSeconds;
                }
                if (spec.tier) existing.tier = spec.tier;
                if (spec.points != null) existing.points = Math.max(0, parseInt(spec.points) || 0);
            } else {
                var target = window.__chickadeeTargetSection;
                var targetSid = (typeof target === 'string' && target) ? target : null;
                items.push({
                    kind: 'script',
                    id: spec.filename,
                    script: spec.filename,
                    tier: spec.tier || (spec.isTest === false ? 'support' : 'public'),
                    points: Math.max(0, parseInt(spec.points) || 1),
                    displayName: '',
                    dependsOn: [],
                    sectionID: targetSid,
                    hint: spec.hint || '',
                    timeLimitSeconds: spec.timeLimitSeconds != null ? spec.timeLimitSeconds : null,
                    _content: spec.content != null ? spec.content : ''
                });
            }
            renderTree();
            return pushSuiteNow()
                .then(function (payload) {
                    var rows = (payload.items || [])
                        .filter(function (i) { return i.kind === 'script' && i.script; })
                        .map(function (i) { return i.script; });
                    return rows.find(function (s) { return s.script === spec.filename; }) || null;
                })
                .catch(function (err) { items = snapshot; renderTree(); throw err; });
        }

        // ── Assignment-wide default per-test time limit (#979) ──
        //
        // Saved through its own endpoint (PUT /instructor/:id/time-limit)
        // rather than PUT /suite, so changing it never closes, re-validates,
        // or retests the assignment (parity with the set_time_limit MCP
        // tool). The input only exists on the edit page; the URL is built
        // from config.assignmentID, so the draft page (no assignmentID, no
        // input) is a double no-op.
        (function wireDefaultTimeLimit() {
            var assignmentID = config.assignmentID;
            if (!assignmentID) return;
            var input  = document.getElementById('suite-default-time-limit');
            var status = document.getElementById('suite-default-limit-status');
            if (!input) return;
            var putTimeLimitURL =
                '/instructor/' + encodeURIComponent(assignmentID) + '/time-limit';
            var lastSaved = input.value;
            var timer = null;
            function save() {
                var raw = input.value.trim();
                var seconds = parseInt(raw, 10);
                if (raw === '' || isNaN(seconds) || seconds < 1 || seconds > 600) {
                    global.ChickadeeUI.setStatus(status, '1–600 s', 'error');
                    return;
                }
                if (String(seconds) === lastSaved) {
                    global.ChickadeeUI.setStatus(status, '');
                    return;
                }
                global.ChickadeeUI.fetchJSON(putTimeLimitURL, {
                    method: 'PUT', csrfToken: csrfToken, body: { seconds: seconds }
                }).then(function (payload) {
                    lastSaved = String((payload && payload.seconds) || seconds);
                    input.value = lastSaved;
                    global.ChickadeeUI.setStatus(status, 'Saved', 'ok');
                }).catch(function (err) {
                    global.ChickadeeUI.setStatus(status,
                        'Save failed: ' + ((err && err.message) || err), 'error');
                });
            }
            input.addEventListener('input', function () {
                if (timer) clearTimeout(timer);
                timer = setTimeout(save, 600);
            });
            input.addEventListener('change', save);
        })();

        // Reload on bfcache restore so the page always reflects server state.
        // Same once-per-document guard as the dragover above, and for the same
        // reason: re-init must not stack another reload handler.  A bfcache
        // restore has already torn any kernel down, so reloading is still the
        // right response on the merged workbench.
        if (!boundPageshow) {
            boundPageshow = true;
            window.addEventListener('pageshow', function (e) {
                if (e.persisted) window.location.reload();
            });
        }

        renderTree();

        return {
            saveFamiliesViaSuite: saveFamiliesViaSuite,
            saveChecksViaSuite: saveChecksViaSuite,
            saveScriptViaSuite: saveScriptViaSuite,
            addExistingScript: addExistingScript,
            getItems: function () { return items.slice(); }
        };
    }

    function noopAPI() {
        return {
            saveFamiliesViaSuite: function () { return Promise.reject(new Error('suite table not ready')); },
            saveChecksViaSuite: function () { return Promise.reject(new Error('suite table not ready')); },
            saveScriptViaSuite: function () { return Promise.reject(new Error('suite table not ready')); },
            addExistingScript: function () {},
            getItems: function () { return []; }
        };
    }

    global.initSuiteTable = initSuiteTable;

    // Node export for the .mjs unit tests (the pure classification helpers
    // only — everything else is DOM-bound).
    if (typeof module === 'object' && module.exports) {
        module.exports = {
            classify: classify,
            classifyFile: classifyFile,
            isLikelyScriptName: isLikelyScriptName,
            hasRecognizedScriptShebang: hasRecognizedScriptShebang,
            // Exported for the config-validation test only. Everything past
            // the urls check is DOM-bound and is not callable under node.
            initSuiteTable: initSuiteTable
        };
    }
})(typeof window !== 'undefined' ? window : globalThis);
