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
//   - handles section rename toggle (.section-edit-toggle / -cancel),
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

    function initSuiteTable(config) {
        config = config || {};
        var csrfToken = config.csrfToken || '';
        var urls      = config.urls || {};
        var formSelector = config.formSelector || 'form.form';

        if (typeof urls.putSuite !== 'function'
         || typeof urls.deleteScript !== 'function'
         || typeof urls.uploadScript !== 'function') {
            throw new Error('initSuiteTable: urls must supply putSuite, deleteScript, uploadScript functions');
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
        function tbodyForSection(sid) {
            var selector = sid
                ? 'tbody[data-section-id="' + sid.replace(/"/g, '\\"') + '"]'
                : 'tbody[data-section-id=""]';
            return container.querySelector(selector);
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
                var s = i.script || {};
                return {
                    kind: 'script',
                    id: s.script || '',
                    script: s.script || '',
                    tier: s.tier || 'public',
                    points: Math.max(1, parseInt(s.points) || 1),
                    displayName: s.displayName == null ? '' : String(s.displayName),
                    dependsOn: (s.dependsOn || []).slice(),
                    sectionID: sid
                };
            });
        }

        function escHtml(v) {
            return String(v == null ? '' : v)
                .replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;')
                .replaceAll('"','&quot;').replaceAll("'",'&#39;');
        }
        function escAttr(v) { return String(v == null ? '' : v).replaceAll('"','&quot;'); }

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

        function depBadgeHTML(dependsOn) {
            if (!dependsOn || !dependsOn.length) return '';
            var labels = dependsOn.map(function (d) {
                if (d.indexOf('family:') === 0) {
                    var fid = d.slice('family:'.length);
                    var fitem = items.find(function (it) {
                        return it.kind === 'family' && it.familyID === fid;
                    });
                    var name = fitem && fitem.family ? fitem.family.name : fid;
                    return '⟳\u00a0' + escHtml(name);
                }
                return escHtml(d);
            });
            return '<span class="suite-dep-badge" title="Runs only after the listed prerequisites pass">↳ ' + labels.join(', ') + '</span>';
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
                +   '<input type="text" class="form-input suite-display-name" value="' + nameVal + '" style="width:12rem;padding:.25rem .5rem;font-size:.8rem">'
                +   depBadgeHTML(item.dependsOn)
                + '</div></td>'
                + '<td><select class="form-input suite-tier" style="padding:.25rem .5rem;font-size:.8rem">'
                +   tierOptions(item.tier)
                + '</select></td>'
                + '<td><input type="number" class="form-input suite-points" min="1" max="100" value="' + pts + '" style="width:4rem;padding:.25rem .5rem;font-size:.8rem"></td>'
                + '<td class="time"><div style="display:flex;gap:.4rem;justify-content:flex-end;flex-wrap:wrap">'
                +   '<button class="btn action-btn suite-edit-btn" type="button" data-filename="' + escAttr(item.script) + '" title="Edit script" aria-label="Edit script" style="padding:.3rem .45rem"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg></button>'
                +   '<button class="btn action-btn action-danger suite-delete-btn" type="button" title="Delete script" aria-label="Delete script" style="padding:.3rem .45rem"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/></svg></button>'
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
            var defaultPoints = Math.max(1, parseInt(defaults.points) || 1);
            var tier = defaults.tier || 'public';
            return '<tr data-id="' + escAttr(item.id) + '" data-kind="family" data-source="family" data-family-id="' + escAttr(family.id || '') + '">'
                + '<td' + indent + '><div class="suite-name-cell">'
                +   '<span class="suite-drag-handle" draggable="true" title="Drag to reorder or adopt">⋮⋮</span>'
                +   connector
                +   '<div style="display:flex;flex-direction:column;gap:.15rem">'
                +     '<strong style="font-size:.85rem">' + escHtml(family.name || family.id || '') + '</strong>'
                +     '<span class="card-meta" style="font-size:.72rem">' + caseText + '</span>'
                +   '</div>'
                + '</div></td>'
                + '<td><select class="form-input suite-family-tier" style="padding:.25rem .5rem;font-size:.8rem">'
                +   ['public','secret','release'].map(function (t) {
                        return '<option value="' + t + '"' + (t === tier ? ' selected' : '') + '>' + t + '</option>';
                    }).join('')
                + '</select></td>'
                + '<td><input type="number" class="form-input suite-family-points" min="1" max="100" value="' + defaultPoints + '" title="Points per case — applied to every generated test" style="width:4rem;padding:.25rem .5rem;font-size:.8rem"></td>'
                + '<td class="time"><div style="display:flex;gap:.4rem;justify-content:flex-end;flex-wrap:wrap">'
                +   '<button class="btn action-btn family-edit-btn" type="button" data-family-id="' + escAttr(family.id || '') + '" title="Edit family" aria-label="Edit family" style="padding:.3rem .45rem"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg></button>'
                +   '<button class="btn action-btn action-danger family-delete-btn" type="button" data-family-id="' + escAttr(family.id || '') + '" title="Delete family" aria-label="Delete family" style="padding:.3rem .45rem"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/></svg></button>'
                + '</div></td>'
                + '</tr>';
        }

        function rowHTML(item, depth) {
            return item.kind === 'family' ? familyRowHTML(item, depth) : scriptRowHTML(item, depth);
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
            var row = container.querySelector('tr[data-id="' + snap.dataID.replace(/"/g, '\\"') + '"]');
            if (!row) return;
            var el = row.querySelector('.' + snap.cls);
            if (!el) return;
            el.focus();
            if (snap.start != null && snap.end != null) {
                try { el.setSelectionRange(snap.start, snap.end); } catch (_) {}
            }
        }

        /// Write rows into every server-rendered tbody.  Items without a
        /// sectionID (or with a stale one) land in the Ungrouped tbody
        /// (data-section-id=""), which the server always renders when any
        /// item is ungrouped.
        function renderTree() {
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
                body.innerHTML = visual.map(function (v) { return rowHTML(v.item, v.depth); }).join('')
                    + '<tr class="suite-root-drop"><td colspan="4">&#9660; Drop here to remove dependency</td></tr>';
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

        // ── Persistence (items only; sections go through dedicated endpoints) ──

        function buildPayload() {
            return {
                items: items.map(function (item) {
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
                    var display = item.displayName && item.displayName.trim();
                    if (display === '' || display === stemOf(item.script)) display = null;
                    return {
                        kind: 'script',
                        script: {
                            script:      item.script,
                            tier:        item.tier,
                            points:      Math.max(1, parseInt(item.points) || 1),
                            displayName: display,
                            dependsOn:   (item.dependsOn || []).slice()
                        },
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
            if (el.classList.contains('suite-display-name')) {
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
            fetch(urls.putSuite(), {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                body: JSON.stringify(buildPayload())
            })
            .then(function (r) {
                if (!r.ok) return r.text().then(function (t) { throw new Error(extractErrorMessage(t) || ('HTTP ' + r.status)); });
                return r.json();
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
                alert('Suite save failed: ' + msg
                    + '\n\nYour edit is still in the page — try again, or reload to recover.');
            })
            .finally(function () {
                pushInFlight = false;
                if (pushPending) { pushPending = false; doPush(); }
            });
        }

        function extractErrorMessage(errBody) {
            if (!errBody) return '';
            var m = errBody.match(/class="error-message"[^>]*>([\s\S]*?)<\/p>/);
            if (m) {
                return m[1].replace(/<[^>]+>/g, '')
                    .replace(/&#39;/g, "'").replace(/&quot;/g, '"')
                    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
                    .trim();
            }
            return errBody.length > 200 ? errBody.substring(0, 200) + '…' : errBody;
        }

        // ── Drag & drop: rows ──

        function clearDropIndicators() {
            container.querySelectorAll('.drop-before,.drop-after,.drop-adopt,.drop-hover,.section-drop-before,.section-drop-after').forEach(function (r) {
                r.classList.remove('drop-before','drop-after','drop-adopt','drop-hover','section-drop-before','section-drop-after');
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
            if (relY < 0.3) {
                target.classList.add('drop-before');
            } else if (relY > 0.7) {
                target.classList.add('drop-after');
            } else if (sameSection && !isChild(tid) && !hasChildrenInSection(dragID, targetSid)) {
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
            // Section-drag: reorder server-rendered sections via AJAX.
            // On 200, update DOM order (we already did client-side) and
            // persist via a POST to /suite-sections/reorder.  No reload —
            // the dashboard pattern doesn't reload on reorder either.
            if (dragSectionID) {
                var overBlock = e.target.closest && e.target.closest('.section-block[data-section-id]');
                if (!overBlock) return;
                var overSid = overBlock.getAttribute('data-section-id');
                if (!overSid || overSid === dragSectionID) return;
                var draggedBlock = container.querySelector('.section-block[data-section-id="' + dragSectionID.replace(/"/g, '\\"') + '"]');
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
                dragItem.sectionID = newSid || null;
                dragItem.dependsOn = [];
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

            if (sameSection && relY >= 0.3 && relY <= 0.7 && !isChild(tid) && !hasChildrenInSection(dragID, targetSid)) {
                dragItem.dependsOn = [tid];
                items = items.filter(function (it) { return it.id !== dragID; });
                var aIdx = items.findIndex(function (it) { return it.id === tid; });
                items.splice(aIdx + 1, 0, dragItem);
            } else {
                dragItem.dependsOn = [];
                if (!sameSection) {
                    dragItem.sectionID = targetSid || null;
                }
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
            var base = (urls.putSuite() || '').replace(/\/suite$/, '/suite-sections/reorder');
            fetch(base, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                body: JSON.stringify({ sectionIDs: ids })
            })
            .then(function (r) {
                if (!r.ok) return r.text().then(function (t) { throw new Error(extractErrorMessage(t) || ('HTTP ' + r.status)); });
            })
            .catch(function (err) {
                console.error('Section reorder failed:', err);
                alert('Section reorder failed: ' + (err.message || err) + '\n\nReload the page to recover.');
            });
        }

        // ── Inline row edits ──

        container.addEventListener('change', function (e) {
            var scriptRow = e.target.closest && e.target.closest('tr[data-kind="script"]');
            if (scriptRow) {
                var item = findByID(scriptRow.getAttribute('data-id'));
                if (!item) return;
                var tierEl = scriptRow.querySelector('.suite-tier');
                var ptsEl  = scriptRow.querySelector('.suite-points');
                if (tierEl) item.tier = tierEl.value;
                if (ptsEl)  item.points = Math.max(1, parseInt(ptsEl.value) || 1);
                schedulePush();
                return;
            }
            var familyRow = e.target.closest && e.target.closest('tr[data-kind="family"]');
            if (familyRow) {
                var fitem = findByID(familyRow.getAttribute('data-id'));
                if (!fitem || !fitem.family) return;
                var tierElF = familyRow.querySelector('.suite-family-tier');
                var ptsElF  = familyRow.querySelector('.suite-family-points');
                var nextDefaults = Object.assign({}, fitem.family.defaults || {});
                if (tierElF) nextDefaults.tier = tierElF.value;
                if (ptsElF)  nextDefaults.points = Math.max(1, parseInt(ptsElF.value) || 1);
                fitem.family = Object.assign({}, fitem.family, { defaults: nextDefaults });
                schedulePush();
            }
        });

        container.addEventListener('input', function (e) {
            var target = e.target;
            if (!target || !target.classList || !target.classList.contains('suite-display-name')) return;
            var row = target.closest('tr[data-kind="script"]');
            if (!row) return;
            var item = findByID(row.getAttribute('data-id'));
            if (!item) return;
            var val = target.value.trim();
            item.displayName = (val && val !== stemOf(item.script)) ? val : '';
        });

        container.addEventListener('change', function (e) {
            var target = e.target;
            if (!target || !target.classList || !target.classList.contains('suite-display-name')) return;
            schedulePush();
        });

        // Delete script row (family delete is handled by pattern-family-editor.js).
        container.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.suite-delete-btn');
            if (!btn) return;
            var row = btn.closest('tr[data-kind="script"]');
            if (!row) return;
            var id = row.getAttribute('data-id');
            var item = findByID(id);
            if (!item) return;
            if (!confirm('Delete test script "' + item.script + '"? This also removes it as a dependency from other items.')) return;

            fetch(urls.deleteScript(item.script), {
                method: 'DELETE',
                headers: { 'x-csrf-token': csrfToken }
            })
            .then(function (r) {
                if (!r.ok && r.status !== 204) return r.text().then(function (t) { throw new Error(extractErrorMessage(t) || ('HTTP ' + r.status)); });
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
                alert('Could not delete: ' + (err.message || err));
            });
        });

        // ── Section-header inline edit (rename toggle + delete) ──

        container.addEventListener('click', function (e) {
            var toggle = e.target.closest && e.target.closest('.section-edit-toggle');
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
            var cancel = e.target.closest && e.target.closest('.section-edit-cancel');
            if (cancel) {
                var header2 = cancel.closest('.section-header');
                if (!header2) return;
                var view2 = header2.querySelector('.section-view');
                var edit2 = header2.querySelector('.section-edit');
                if (view2) view2.style.display = 'flex';
                if (edit2) edit2.style.display = 'none';
                return;
            }
            var del = e.target.closest && e.target.closest('.section-delete-btn');
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
                if (!confirm(msg)) return;
                var f = document.createElement('form');
                f.method = 'POST';
                f.action = action;
                var t = document.createElement('input');
                t.type = 'hidden'; t.name = '_csrf'; t.value = csrfToken;
                f.appendChild(t);
                document.body.appendChild(f);
                f.submit();
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
                        return global.ChickadeeSuiteList.classifyFile(file).then(function (cls) {
                            return file.text().then(function (content) {
                                return fetch(urls.uploadScript(), {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                                    body: JSON.stringify({
                                        filename: file.name,
                                        content: content,
                                        tier: cls.tier,
                                        points: 1,
                                        isTest: cls.isScript
                                    })
                                }).then(function (r) {
                                    if (!r.ok) return r.text().then(function (t) { throw new Error(extractErrorMessage(t) || ('HTTP ' + r.status)); });
                                    return r.json();
                                }).then(function (data) {
                                    addExistingScript(data);
                                });
                            });
                        });
                    });
                });
                chain.catch(function (err) { alert('Upload failed: ' + (err.message || err)); });
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
        if (form) {
            form.addEventListener('submit', function (e) {
                if (pushTimer) { clearTimeout(pushTimer); pushTimer = null; }
                var sectionVarsPromise = (typeof window.chickadeeFlushSectionVars === 'function')
                    ? window.chickadeeFlushSectionVars()
                    : Promise.resolve();
                if (pushInFlight || pushPending) {
                    e.preventDefault();
                    var iv = setInterval(function () {
                        if (!pushInFlight && !pushPending) {
                            clearInterval(iv);
                            sectionVarsPromise.finally(function () { form.submit(); });
                        }
                    }, 50);
                } else {
                    // No suite PUT pending — still wait for section-vars
                    // if they're in flight, since they might have been
                    // triggered by the same keystroke that led here.
                    e.preventDefault();
                    sectionVarsPromise.finally(function () { form.submit(); });
                }
            });
        }

        /// Adds a newly-created script to the local items list and pushes.
        /// Lands ungrouped; instructor can drag into a section after.
        function addExistingScript(script) {
            if (!script || !script.filename) return;
            items = items.filter(function (it) {
                return !(it.kind === 'script' && it.script === script.filename);
            });
            items.push({
                kind: 'script',
                id: script.filename,
                script: script.filename,
                tier: script.tier || (script.isTest ? 'public' : 'support'),
                points: Math.max(1, parseInt(script.points) || 1),
                displayName: '',
                dependsOn: [],
                sectionID: null
            });
            renderTree();
            schedulePush();
        }

        /// Reconciles the local state with the full family list returned
        /// from `PUT /families`.
        function syncFamilies(nextFamilies) {
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

            (nextFamilies || []).forEach(function (f) {
                if (seen[f.id]) return;
                items.push({
                    kind: 'family',
                    id: 'family:' + f.id,
                    familyID: f.id,
                    family: f,
                    dependsOn: (f.dependsOn || []).slice(),
                    sectionID: null
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
            renderTree();
            schedulePush();
        }

        // Reload on bfcache restore so the page always reflects server state.
        window.addEventListener('pageshow', function (e) {
            if (e.persisted) window.location.reload();
        });

        renderTree();

        return {
            syncFamilies: syncFamilies,
            addExistingScript: addExistingScript,
            getItems: function () { return items.slice(); }
        };
    }

    function noopAPI() {
        return {
            syncFamilies: function () {},
            addExistingScript: function () {},
            getItems: function () { return []; }
        };
    }

    global.initSuiteTable = initSuiteTable;
})(window);
