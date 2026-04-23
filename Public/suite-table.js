// Chickadee — Suite Table editor
//
// Browser-side module that drives the multi-section suite editor on the
// instructor assignment edit page.  Factored out of
// Resources/Views/assignment-edit.leaf in v0.4.91; extended in v0.4.96
// to group items into Sections (one table per section, drag across
// tables, add/rename/delete section).  When the assignment has no
// sections the module renders one unlabelled block that looks
// identical to the pre-sections layout.
//
// DOM contract (assignment-edit.leaf):
//
//   div#suite-sections               — mount point; JS owns all markup inside
//   input#suite-files-input          — optional upload input
//   button#add-test-btn              — optional "Upload" trigger
//   button#add-section-btn           — optional "+ Section" trigger
//   script#suite-state-seed          — JSON seed (same shape as GET /suite)
//
// Host wires the module via:
//
//   var suiteTable = window.initSuiteTable({
//       assignmentID?: 'TWTFKZ',             // edit mode
//       draftID?:      'setup_ab12...',      // reserved for future use
//       csrfToken:     '<token>',
//       formSelector:  'form.form',          // parent form for submit flush
//       urls: {
//           putSuite:     function () {...}, // PUT endpoint for items+sections
//           deleteScript: function (name) {...}, // DELETE per-script
//           uploadScript: function () {...}  // POST per-script upload
//       }
//   })
//
// Returns `{ syncFamilies(applied), addExistingScript(script), getItems() }`.

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
        var sections = [];
        var dragID        = null;   // row drag
        var dragSectionID = null;   // section drag
        var pushTimer = null;
        var pushInFlight = false;
        var pushPending = false;

        // Seed from the server-rendered JSON blob — same shape as
        // `GET /suite`.
        (function seed() {
            var el = document.getElementById('suite-state-seed');
            if (!el) return;
            var payload;
            try { payload = JSON.parse(el.textContent || '{"items":[],"sections":[]}'); }
            catch (_) { payload = { items: [], sections: [] }; }
            sections = normaliseSections(payload.sections || []);
            items    = normaliseItems(payload.items || []);
            items    = sortItemsBySection(items);
        })();

        function normaliseSections(raw) {
            return (raw || []).map(function (s) {
                return { id: String(s.id || ''), name: String(s.name || '') };
            }).filter(function (s) { return s.id; });
        }

        function normaliseItems(raw) {
            var validSectionIDs = {};
            sections.forEach(function (s) { validSectionIDs[s.id] = true; });
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

        /// Produces a canonical item order: all section-A items (in their
        /// authored order), then section-B items, ..., then ungrouped.
        /// This is the order the server's contiguity check expects, and
        /// the order we want both in `items[]` and in the PUT payload.
        function sortItemsBySection(list) {
            var sectionIndex = {};
            sections.forEach(function (s, i) { sectionIndex[s.id] = i; });
            var withOrder = list.map(function (it, origIndex) {
                var sid = it.sectionID || null;
                var rank = sid && sectionIndex.hasOwnProperty(sid)
                    ? sectionIndex[sid]
                    : sections.length; // ungrouped last
                return { it: it, rank: rank, origIndex: origIndex };
            });
            withOrder.sort(function (a, b) {
                if (a.rank !== b.rank) return a.rank - b.rank;
                return a.origIndex - b.origIndex;
            });
            return withOrder.map(function (x) { return x.it; });
        }

        function escHtml(v) {
            return String(v == null ? '' : v)
                .replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;')
                .replaceAll('"','&quot;').replaceAll("'",'&#39;');
        }
        function escAttr(v) { return String(v == null ? '' : v).replaceAll('"','&quot;'); }

        function findByID(id) { return items.find(function (it) { return it.id === id; }); }
        function findSectionByID(id) {
            for (var i = 0; i < sections.length; i++) {
                if (sections[i].id === id) return sections[i];
            }
            return null;
        }

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

        function uniqueID() {
            try {
                if (crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
            } catch (_) {}
            return 's-' + Math.random().toString(36).slice(2, 10) + '-' + Date.now().toString(36);
        }

        /// Returns the visual-order list (with 1-level parent/child indent)
        /// for items in a given section.  Only `dependsOn[0]` drives the
        /// visual tree; the underlying `dependsOn` stays free-form.
        function visualOrderForSection(sid) {
            var sectionItems = itemsInSection(sid);
            var result = [];
            var byID = {};
            sectionItems.forEach(function (it) { byID[it.id] = it; });
            var childMap = {};
            sectionItems.forEach(function (it) {
                if (it.dependsOn && it.dependsOn.length > 0) {
                    var p = it.dependsOn[0];
                    // Only treat as a child in the tree if the parent is
                    // in the same section (cross-section deps don't
                    // indent visually).
                    if (byID[p]) {
                        childMap[p] = childMap[p] || [];
                        childMap[p].push(it);
                    }
                }
            });
            sectionItems.filter(function (it) {
                if (!it.dependsOn || it.dependsOn.length === 0) return true;
                // Treat as root within the section if its parent isn't
                // in this section.
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

        function tableHTMLForSection(sid) {
            var visual = visualOrderForSection(sid);
            var body = visual.map(function (v) { return rowHTML(v.item, v.depth); }).join('');
            var dropZone = '<tr class="suite-root-drop"><td colspan="4">&#9660; Drop here to remove dependency</td></tr>';
            return '<table class="results-table" style="width:100%"><thead><tr>'
                 + '<th title="Student-facing name (edit to override the filename)">Name</th>'
                 + '<th>Visibility</th>'
                 + '<th title="Grade point weight for this test (default 1)">Pts</th>'
                 + '<th class="time">Action</th>'
                 + '</tr></thead><tbody data-section-id="' + escAttr(sid || '') + '">'
                 + body + dropZone
                 + '</tbody></table>';
        }

        function sectionBlockHTML(section) {
            var isUngrouped = !section;
            var sid         = section ? section.id   : '';
            var name        = section ? section.name : 'Ungrouped';
            var header;
            if (isUngrouped) {
                header = '<div class="section-header" style="display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;margin-bottom:.4rem;padding:.4rem .6rem;background:var(--gray-100,#f5f5f5);border-radius:.4rem">'
                       +   '<strong class="suite-section-name-label" style="font-size:.9rem;color:var(--gray-600)">' + escHtml(name) + '</strong>'
                       +   '<span class="card-meta" style="font-size:.72rem;color:var(--gray-500)">Tests not yet assigned to a section</span>'
                       + '</div>';
            } else {
                header = '<div class="section-header" draggable="true" style="display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;margin-bottom:.4rem;padding:.4rem .6rem;background:var(--gray-100,#f5f5f5);border-radius:.4rem">'
                       +   '<span class="section-drag-handle" title="Drag to reorder section" style="cursor:grab;user-select:none;font-weight:700;color:var(--gray-500)">⋮⋮</span>'
                       +   '<input type="text" class="form-input suite-section-name-input" data-section-id="' + escAttr(sid) + '" value="' + escAttr(name) + '" placeholder="Section name" style="flex:1;min-width:12rem;padding:.25rem .5rem;font-size:.9rem;font-weight:600">'
                       +   '<button class="btn action-btn action-danger suite-section-delete-btn" type="button" data-section-id="' + escAttr(sid) + '" title="Delete section" aria-label="Delete section" style="padding:.3rem .45rem"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/></svg></button>'
                       + '</div>';
            }
            return '<div class="section-block" data-section-id="' + escAttr(sid) + '" style="margin-bottom:1.25rem">'
                 + header
                 + tableHTMLForSection(sid || null)
                 + '</div>';
        }

        /// Preserves which input (row-level or section-name) was focused
        /// and where the caret sat, across `innerHTML` rebuilds triggered
        /// by debounced `PUT /suite` responses.
        function captureFocus() {
            var el = document.activeElement;
            if (!el || !container.contains(el)) return null;
            var start = null, end = null;
            try { start = el.selectionStart; end = el.selectionEnd; } catch (_) {}
            // Section-name input: keyed by its data-section-id.
            if (el.classList && el.classList.contains('suite-section-name-input')) {
                return { kind: 'section', sectionID: el.getAttribute('data-section-id'), start: start, end: end };
            }
            var row = el.closest && el.closest('tr[data-id]');
            if (!row) return null;
            var cls = (el.className || '').split(/\s+/).filter(function (c) {
                return c && c.indexOf('form-') !== 0;
            })[0];
            if (!cls) return null;
            return { kind: 'row', dataID: row.getAttribute('data-id'), cls: cls, start: start, end: end };
        }

        function restoreFocus(snap) {
            if (!snap) return;
            var el = null;
            if (snap.kind === 'section') {
                el = container.querySelector('.suite-section-name-input[data-section-id="' + (snap.sectionID || '').replace(/"/g, '\\"') + '"]');
            } else if (snap.kind === 'row') {
                var row = container.querySelector('tr[data-id="' + snap.dataID.replace(/"/g, '\\"') + '"]');
                if (row) el = row.querySelector('.' + snap.cls);
            }
            if (!el) return;
            el.focus();
            if (snap.start != null && snap.end != null) {
                try { el.setSelectionRange(snap.start, snap.end); } catch (_) {}
            }
        }

        function renderTree() {
            var focusSnap = captureFocus();
            // Always keep items[] in canonical order so drop handlers
            // and the PUT payload agree.
            items = sortItemsBySection(items);
            var blocks = sections.map(sectionBlockHTML);
            var anyUngrouped = items.some(function (it) {
                var sid = it.sectionID || null;
                return !sid || !findSectionByID(sid);
            });
            // The "Ungrouped" block renders in two cases:
            //   1. There are items without a section (so we need somewhere
            //      to show them), OR
            //   2. There are no sections at all — in which case the
            //      "Ungrouped" block is the ONLY block, but its header
            //      reads "Ungrouped" which is misleading.  Use a slim
            //      header-less presentation in that case.
            if (anyUngrouped || sections.length === 0) {
                blocks.push(sectionBlockHTML(null));
            }
            container.innerHTML = blocks.join('');
            // Hide the "Ungrouped" header when no sections exist — the
            // page should look identical to the pre-sections layout.
            if (sections.length === 0) {
                var lastBlock = container.querySelector('.section-block:last-child .section-header');
                if (lastBlock) lastBlock.style.display = 'none';
            }
            restoreFocus(focusSnap);
        }

        // ── Persistence ──────────────────────────────────────────────────

        /// Builds the `PUT /suite` request body from the current items[]
        /// and sections[].  Items are emitted in canonical (section, then
        /// authored) order so the server's contiguity check always passes.
        function buildPayload() {
            return {
                sections: sections.map(function (s) { return { id: s.id, name: s.name }; }),
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
                sections = normaliseSections(payload.sections || []);
                items    = normaliseItems(payload.items || []);
                items    = sortItemsBySection(items);
                renderTree();
            })
            .catch(function (err) {
                console.error('Suite save failed:', err);
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
                // Adopt only inside the same section — cross-section visual
                // parenting doesn't make sense.
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
            // Section-drag drop → reorder sections[].
            if (dragSectionID) {
                var overBlock = e.target.closest && e.target.closest('.section-block[data-section-id]');
                if (!overBlock) return;
                var overSid = overBlock.getAttribute('data-section-id');
                if (!overSid || overSid === dragSectionID) return;
                var fromIdx = sections.findIndex(function (s) { return s.id === dragSectionID; });
                var toIdx   = sections.findIndex(function (s) { return s.id === overSid; });
                if (fromIdx < 0 || toIdx < 0) return;
                var brect2 = overBlock.getBoundingClientRect();
                var afterBlock2 = e.clientY > brect2.top + brect2.height / 2;
                var moving = sections.splice(fromIdx, 1)[0];
                var insertAt = sections.findIndex(function (s) { return s.id === overSid; });
                if (insertAt < 0) insertAt = sections.length;
                sections.splice(afterBlock2 ? insertAt + 1 : insertAt, 0, moving);
                renderTree(); schedulePush();
                return;
            }
            if (!dragID) return;
            var dragItem = findByID(dragID);
            if (!dragItem) return;

            var rootZone = e.target.closest && e.target.closest('.suite-root-drop');
            if (rootZone) {
                // Drop on a root-zone re-homes to that tbody's section and
                // clears dependsOn.  (Per-section root zones let the
                // instructor move an item into the Ungrouped block by
                // dropping onto its root zone.)
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
                // Adopt within the same section.
                dragItem.dependsOn = [tid];
                items = items.filter(function (it) { return it.id !== dragID; });
                var aIdx = items.findIndex(function (it) { return it.id === tid; });
                items.splice(aIdx + 1, 0, dragItem);
            } else {
                // Reorder (same section) or cross-section move.  Clear
                // deps; preserving them across section boundaries can
                // create visual-tree orphans.
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

        // ── Inline script / family edits ────────────────────────────────

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

        // Display-name edits use a two-phase model to avoid a race between
        // live typing and the debounced `PUT /suite` response.
        container.addEventListener('input', function (e) {
            var target = e.target;
            if (!target || !target.classList) return;
            if (target.classList.contains('suite-display-name')) {
                var row = target.closest('tr[data-kind="script"]');
                if (!row) return;
                var item = findByID(row.getAttribute('data-id'));
                if (!item) return;
                var val = target.value.trim();
                item.displayName = (val && val !== stemOf(item.script)) ? val : '';
                return;
            }
            if (target.classList.contains('suite-section-name-input')) {
                var sid = target.getAttribute('data-section-id');
                var sec = findSectionByID(sid);
                if (sec) sec.name = target.value;
            }
        });

        container.addEventListener('change', function (e) {
            var target = e.target;
            if (!target || !target.classList) return;
            if (target.classList.contains('suite-display-name')) {
                schedulePush();
            } else if (target.classList.contains('suite-section-name-input')) {
                schedulePush();
            }
        });

        // Delete script row or delete section.
        container.addEventListener('click', function (e) {
            var secBtn = e.target.closest && e.target.closest('.suite-section-delete-btn');
            if (secBtn) {
                var sid = secBtn.getAttribute('data-section-id');
                var sec = findSectionByID(sid);
                if (!sec) return;
                var affected = itemsInSection(sid).length;
                var msg;
                if (affected === 0) {
                    msg = 'Delete section "' + sec.name + '"?';
                } else {
                    msg = 'Delete section "' + sec.name + '"? Its ' + affected + ' test' + (affected === 1 ? '' : 's') + ' will move to Ungrouped.';
                }
                if (!confirm(msg)) return;
                sections = sections.filter(function (s) { return s.id !== sid; });
                items.forEach(function (it) { if (it.sectionID === sid) it.sectionID = null; });
                renderTree(); schedulePush();
                return;
            }
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

        var addSectionBtn = document.getElementById('add-section-btn');
        if (addSectionBtn) {
            addSectionBtn.addEventListener('click', function () {
                sections.push({ id: uniqueID(), name: 'Untitled section' });
                renderTree();
                schedulePush();
                // Focus the new section's name input so the instructor
                // can rename it without a second click.
                var inputs = container.querySelectorAll('.suite-section-name-input');
                var last = inputs[inputs.length - 1];
                if (last) { last.focus(); last.select(); }
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
        /// when a brand-new file has been saved.  New scripts land in the
        /// Ungrouped bucket (sectionID = null); the instructor can drag
        /// them into a section afterwards.
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
