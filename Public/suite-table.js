// Chickadee — Suite Table editor
//
// Browser-side module that drives the unified suite table on the
// instructor assignment authoring pages.  Factored out of
// Resources/Views/assignment-edit.leaf in v0.4.91 so the Create and Edit
// pages share one implementation of drag/drop reorder, dependency adopt,
// tier / points / display-name inline edits, and `PUT /suite`
// persistence.
//
// The table HTML stays in the Leaf template (see the `suite-config-table`
// markup block).  This module assumes the following DOM IDs / classes:
//
//   tbody#suite-config-body          — rows live here
//   input#suite-files-input          — optional upload input
//   button#add-test-btn              — optional "Add Tests" trigger
//   .suite-drag-handle               — drag grip inside each row
//   .suite-display-name              — per-row display-name input
//   .suite-tier / .suite-points      — per-row script controls
//   .suite-family-tier / .suite-family-points — per-row family controls
//   .suite-edit-btn / .suite-delete-btn        — script actions
//   .family-edit-btn / .family-delete-btn      — family actions
//                                      (wired by pattern-family-editor.js)
//   .suite-root-drop                 — synthetic drop zone under the table
//   script#suite-state-seed          — JSON seed (same shape as GET /suite)
//
// Host wires the module via:
//
//   var suiteTable = window.initSuiteTable({
//       assignmentID?: 'TWTFKZ',             // edit mode
//       draftID?:      'setup_ab12...',      // future create-draft mode
//       csrfToken:     '<token>',
//       formSelector:  'form.form',          // parent form for submit flush
//       urls: {
//           putSuite:     function () {...}, // PUT endpoint for items[]
//           deleteScript: function (name) {...}, // DELETE per-script
//           uploadScript: function () {...}  // POST per-script upload
//       }
//   })
//
// Returns `{ syncFamilies(applied), addExistingScript(script), getItems() }`.
// The host typically wires the two public hooks to globals so the existing
// pattern-family-editor and script-editor modules keep working unchanged:
//
//   window.chickadeeAddExistingSuiteScript = suiteTable.addExistingScript;
//   window.chickadeeSyncFamilies           = suiteTable.syncFamilies;

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
        var body        = document.getElementById('suite-config-body');
        var form        = document.querySelector(formSelector);
        if (!body) return noopAPI();

        var items = [];
        var dragID = null;
        var pushTimer = null;
        var pushInFlight = false;
        var pushPending = false;

        // Seed from the server-rendered JSON blob — same shape as
        // `GET /suite`.
        (function seed() {
            var el = document.getElementById('suite-state-seed');
            if (!el) return;
            var payload;
            try { payload = JSON.parse(el.textContent || '{"items":[]}'); }
            catch (_) { payload = { items: [] }; }
            items = normaliseItems(payload.items || []);
        })();

        function normaliseItems(raw) {
            return (raw || []).map(function (i) {
                if (i.kind === 'family' && i.family) {
                    var fid = i.family.id;
                    return {
                        kind: 'family',
                        id: 'family:' + fid,
                        familyID: fid,
                        family: i.family,
                        dependsOn: (i.dependsOn && i.dependsOn.length)
                            ? i.dependsOn.slice()
                            : (i.family.dependsOn || []).slice()
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
                    dependsOn: (s.dependsOn || []).slice()
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
        function hasChildren(id) {
            return items.some(function (it) { return it.dependsOn.indexOf(id) >= 0; });
        }
        function isChild(id) {
            var it = findByID(id);
            return it ? (it.dependsOn && it.dependsOn.length > 0) : false;
        }

        function visualOrder() {
            // One-level parent/child tree keyed by item id.  Only the first
            // element of dependsOn is used for the visual parent link; the
            // actual dependency list (which can be multi-valued, including
            // family refs) is preserved unchanged on the item.
            var result = [];
            var childMap = {};
            items.forEach(function (it) {
                if (it.dependsOn && it.dependsOn.length > 0) {
                    var p = it.dependsOn[0];
                    childMap[p] = childMap[p] || [];
                    childMap[p].push(it);
                }
            });
            items.filter(function (it) {
                return !it.dependsOn || it.dependsOn.length === 0;
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

        function stemOf(filename) {
            var dot = filename.lastIndexOf('.');
            return dot > 0 ? filename.slice(0, dot) : filename;
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

        /// Preserves which cell was focused (and where the caret sat) across
        /// the `innerHTML` rebuild.  Without this, a debounced `PUT /suite`
        /// fired by the previous keystroke wipes the `<input>` the user is
        /// still typing into — dropping focus and caret position mid-rename.
        function captureFocus() {
            var el = document.activeElement;
            if (!el || !body.contains(el)) return null;
            var row = el.closest('tr[data-id]');
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
            var row = body.querySelector('tr[data-id="' + snap.dataID.replace(/"/g, '\\"') + '"]');
            if (!row) return;
            var el = row.querySelector('.' + snap.cls);
            if (!el) return;
            el.focus();
            if (snap.start != null && snap.end != null) {
                try { el.setSelectionRange(snap.start, snap.end); } catch (_) {}
            }
        }

        function renderTree() {
            var focusSnap = captureFocus();
            var visual = visualOrder();
            body.innerHTML = visual.map(function (v) { return rowHTML(v.item, v.depth); }).join('')
                + '<tr class="suite-root-drop"><td colspan="4">&#9660; Drop here to remove dependency</td></tr>';
            restoreFocus(focusSnap);
        }

        // ── Persistence ──────────────────────────────────────────────────

        /// Builds the `PUT /suite` request body from the current `items[]`.
        function buildPayload() {
            return {
                items: items.map(function (item) {
                    if (item.kind === 'family') {
                        // Stamp the row-level dependsOn onto the family spec
                        // server-side too, so the payload is self-contained.
                        var family = Object.assign({}, item.family);
                        family.dependsOn = item.dependsOn ? item.dependsOn.slice() : [];
                        return { kind: 'family', family: family, dependsOn: family.dependsOn.slice() };
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
                        }
                    };
                })
            };
        }

        function schedulePush() {
            if (pushTimer) clearTimeout(pushTimer);
            pushTimer = setTimeout(doPush, 300);
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
                items = normaliseItems(payload.items || []);
                renderTree();
            })
            .catch(function (err) {
                console.error('Suite save failed:', err);
                // Rehydrate from server so the UI doesn't stay on a rejected state.
                window.location.reload();
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

        // ── Drag & drop ──────────────────────────────────────────────────

        function clearDropIndicators() {
            body.querySelectorAll('.drop-before,.drop-after,.drop-adopt,.drop-hover').forEach(function (r) {
                r.classList.remove('drop-before','drop-after','drop-adopt','drop-hover');
            });
        }

        body.addEventListener('dragstart', function (e) {
            var handle = e.target.closest && e.target.closest('.suite-drag-handle');
            if (!handle) { e.preventDefault(); return; }
            var row = handle.closest('tr[data-id]');
            if (!row) { e.preventDefault(); return; }
            dragID = row.getAttribute('data-id');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', dragID);
            row.classList.add('suite-row-dragging');
        });

        body.addEventListener('dragend', function () {
            dragID = null;
            body.querySelectorAll('.suite-row-dragging').forEach(function (r) { r.classList.remove('suite-row-dragging'); });
            clearDropIndicators();
        });

        body.addEventListener('dragover', function (e) {
            if (!dragID) return;
            e.preventDefault();
            clearDropIndicators();
            var rootZone = e.target.closest && e.target.closest('.suite-root-drop');
            if (rootZone) { rootZone.classList.add('drop-hover'); return; }
            var target = e.target.closest && e.target.closest('tr[data-id]');
            if (!target) return;
            var tid = target.getAttribute('data-id');
            if (tid === dragID) return;
            var rect  = target.getBoundingClientRect();
            var relY  = (e.clientY - rect.top) / rect.height;
            if (relY < 0.3) {
                target.classList.add('drop-before');
            } else if (relY > 0.7) {
                target.classList.add('drop-after');
            } else if (!isChild(tid) && !hasChildren(dragID)) {
                target.classList.add('drop-adopt');
            } else {
                target.classList.add(relY < 0.5 ? 'drop-before' : 'drop-after');
            }
        });

        body.addEventListener('dragleave', function (e) {
            var row = e.target.closest && e.target.closest('tr');
            if (row) row.classList.remove('drop-before','drop-after','drop-adopt','drop-hover');
        });

        body.addEventListener('drop', function (e) {
            e.preventDefault();
            if (!dragID) return;
            var dragItem = findByID(dragID);
            if (!dragItem) return;

            var rootZone = e.target.closest && e.target.closest('.suite-root-drop');
            if (rootZone) {
                dragItem.dependsOn = [];
                renderTree(); schedulePush(); return;
            }

            var target = e.target.closest && e.target.closest('tr[data-id]');
            if (!target) return;
            var tid = target.getAttribute('data-id');
            if (!tid || tid === dragID) return;

            var rect = target.getBoundingClientRect();
            var relY = (e.clientY - rect.top) / rect.height;

            if (relY >= 0.3 && relY <= 0.7 && !isChild(tid) && !hasChildren(dragID)) {
                dragItem.dependsOn = [tid];
            } else {
                dragItem.dependsOn = [];
                items = items.filter(function (it) { return it.id !== dragID; });
                var tIdx = items.findIndex(function (it) { return it.id === tid; });
                items.splice(relY <= 0.5 ? tIdx : tIdx + 1, 0, dragItem);
            }
            renderTree(); schedulePush();
        });

        // ── Inline script edits ──────────────────────────────────────────

        body.addEventListener('change', function (e) {
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

        // Display-name edits use a two-phase model to avoid a race between
        // live typing and the debounced `PUT /suite` response.  See v0.4.87.
        body.addEventListener('input', function (e) {
            var target = e.target;
            if (!target || !target.classList || !target.classList.contains('suite-display-name')) return;
            var row = target.closest('tr[data-kind="script"]');
            if (!row) return;
            var item = findByID(row.getAttribute('data-id'));
            if (!item) return;
            var val = target.value.trim();
            item.displayName = (val && val !== stemOf(item.script)) ? val : '';
        });

        body.addEventListener('change', function (e) {
            var target = e.target;
            if (!target || !target.classList || !target.classList.contains('suite-display-name')) return;
            schedulePush();
        });

        // Delete script row (family delete is handled by pattern-family-editor.js).
        body.addEventListener('click', function (e) {
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

        // Upload button: stream uploaded files straight through the per-script
        // CRUD endpoint rather than queueing them.
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

        // Flush any pending suite-state push before letting the multipart
        // form submit.
        if (form) {
            form.addEventListener('submit', function (e) {
                if (pushTimer) { clearTimeout(pushTimer); pushTimer = null; }
                if (pushInFlight || pushPending) {
                    e.preventDefault();
                    var iv = setInterval(function () {
                        if (!pushInFlight && !pushPending) {
                            clearInterval(iv);
                            form.submit();
                        }
                    }, 50);
                }
            });
        }

        /// Adds a newly-created script to the local items list and pushes
        /// the updated suite.  Public hook used by the Script Editor modal
        /// when a brand-new file has been saved.
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
                dependsOn: []
            });
            renderTree();
            schedulePush();
        }

        /// Reconciles the local state with the full family list returned
        /// from `PUT /families`.  Preserves positions + dependencies of
        /// families that were already in the list; appends newcomers;
        /// removes deleted ones (and drops their ids from dependsOn lists).
        function syncFamilies(nextFamilies) {
            var byID = {};
            (nextFamilies || []).forEach(function (f) { byID[f.id] = f; });

            var seen = {};
            items = items.map(function (item) {
                if (item.kind !== 'family') return item;
                var f = byID[item.familyID];
                if (!f) return null; // family was removed
                seen[item.familyID] = true;
                return {
                    kind: 'family',
                    id: 'family:' + f.id,
                    familyID: f.id,
                    family: f,
                    dependsOn: (f.dependsOn || []).slice()
                };
            }).filter(Boolean);

            (nextFamilies || []).forEach(function (f) {
                if (seen[f.id]) return;
                items.push({
                    kind: 'family',
                    id: 'family:' + f.id,
                    familyID: f.id,
                    family: f,
                    dependsOn: (f.dependsOn || []).slice()
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
