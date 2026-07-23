// section-items-dnd.js
//
// Drag-and-drop for the instructor dashboard's unified section item list.
// Assignments and ungraded content items interleave in one drag-orderable
// sequence per section, so a reading can sit between two labs. Extracted from
// the inline assignments.leaf <script> (net inline-JS shrink) and generalised
// from assignment-only to both row types.
//
// Each draggable row is either an assignment (`data-assignment-id`) or a
// content item (`data-content-item-id`), living together in a section tbody
// (`data-section-id`, empty string = ungrouped). Dragging within a tbody posts
// the mixed order to POST /instructor/section-items/reorder; dragging to
// another tbody moves the item (per-type section endpoint), reorders the
// destination to the dropped position, and reloads.
//
// Runs after chickadee-ui.js (base.leaf) — uses ChickadeeUI.getCsrfToken().
// Decoupled from the section-reorder DnD (still inline) by that handler's
// stopPropagation on the section header.
(function () {
    'use strict';

    var ROW_SELECTOR = 'tr[data-assignment-id], tr[data-content-item-id]';
    var csrfToken = (window.ChickadeeUI && window.ChickadeeUI.getCsrfToken)
        ? window.ChickadeeUI.getCsrfToken()
        : '';

    // {type, id} for a row — the shape the reorder/move endpoints accept.
    function descriptor(row) {
        var assignmentID = row.getAttribute('data-assignment-id');
        if (assignmentID) return { type: 'assignment', id: assignmentID };
        return { type: 'content', id: row.getAttribute('data-content-item-id') };
    }

    function currentItems(tbody) {
        return Array.from(tbody.querySelectorAll(ROW_SELECTOR)).map(descriptor);
    }

    function orderKey(tbody) {
        return currentItems(tbody).map(function (d) { return d.type + ':' + d.id; }).join(',');
    }

    function postJSON(url, body) {
        return fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
            body: JSON.stringify(body)
        });
    }

    // Persist a within-section reorder: the tbody's full mixed order, 1..n.
    function persistReorder(tbody) {
        return postJSON('/instructor/section-items/reorder', {
            sectionID: tbody.getAttribute('data-section-id') || '',
            items: currentItems(tbody)
        }).then(function (res) {
            if (!res.ok) window.location.reload();
        });
    }

    // Move a row to another section (per-type endpoint), then renumber the
    // destination to the dropped position so cross-section placement is exact.
    function persistMove(row, destTbody) {
        var d = descriptor(row);
        var sectionID = destTbody.getAttribute('data-section-id') || '';
        var moveURL = d.type === 'assignment'
            ? '/instructor/' + d.id + '/section'
            : '/instructor/content-items/' + d.id + '/section';
        postJSON(moveURL, { sectionID: sectionID })
            .then(function () {
                return postJSON('/instructor/section-items/reorder', {
                    sectionID: sectionID,
                    items: currentItems(destTbody)
                });
            })
            .then(function () { window.location.reload(); })
            .catch(function () { window.location.reload(); });
    }

    var dragged = null;
    var startTbody = null;
    var startOrder = '';

    function makeDraggable(root) {
        root.querySelectorAll(ROW_SELECTOR).forEach(function (row) {
            row.classList.add('assignment-draggable');
            row.setAttribute('draggable', 'true');
            // Prevent native link / image drag from hijacking the row drag.
            row.querySelectorAll('a, img').forEach(function (el) {
                el.setAttribute('draggable', 'false');
            });
        });
    }
    makeDraggable(document);

    document.addEventListener('dragstart', function (event) {
        var target = event.target;
        if (!(target instanceof Element)) return;
        var row = target.closest(ROW_SELECTOR);
        if (!row) return;
        dragged = row;
        startTbody = row.parentElement;
        startOrder = orderKey(startTbody);
        row.classList.add('dragging');
        if (event.dataTransfer) {
            event.dataTransfer.effectAllowed = 'move';
            var d = descriptor(row);
            event.dataTransfer.setData('text/plain', d.id || '');
        }
    });

    document.addEventListener('dragover', function (event) {
        if (!dragged) return;
        // preventDefault unconditionally so the drop cursor stays valid even
        // over empty table space after the row has already moved tbodies.
        event.preventDefault();
        var target = event.target;
        if (!(target instanceof Element)) return;

        // 1. Over another item row — insert before or after it.
        var overRow = target.closest(ROW_SELECTOR);
        if (overRow && overRow !== dragged) {
            var rect = overRow.getBoundingClientRect();
            var after = event.clientY > rect.top + rect.height / 2;
            overRow.parentElement.insertBefore(dragged, after ? overRow.nextSibling : overRow);
            return;
        }

        // 2. Over an empty-section placeholder row — move into that section.
        var emptyRow = target.closest('tr.section-empty-row');
        if (emptyRow) {
            emptyRow.style.display = 'none';
            emptyRow.parentElement.insertBefore(dragged, emptyRow);
            return;
        }

        // 3. Over a tbody but not a specific row — append if from another section.
        var dropTbody = target.closest('tbody[data-section-id]');
        if (dropTbody && dragged.parentElement !== dropTbody) {
            dropTbody.appendChild(dragged);
            return;
        }

        // 4. Over a section block's header / gap — move into that block's tbody.
        var overBlock = target.closest('.section-block[data-section-id]');
        if (overBlock) {
            var blockTbody = overBlock.querySelector('tbody[data-section-id]');
            if (blockTbody && dragged.parentElement !== blockTbody) {
                blockTbody.appendChild(dragged);
            }
        }
    });

    document.addEventListener('drop', function (event) {
        if (!dragged) return;
        event.preventDefault();
    });

    document.addEventListener('dragend', function () {
        if (!dragged) return;
        dragged.classList.remove('dragging');
        var row = dragged;
        var fromTbody = startTbody;
        var fromOrder = startOrder;
        dragged = null;
        startTbody = null;
        startOrder = '';

        var nowTbody = row.parentElement;
        if (!nowTbody) return;

        if (nowTbody !== fromTbody) {
            persistMove(row, nowTbody);
        } else if (orderKey(nowTbody) !== fromOrder) {
            persistReorder(nowTbody).catch(function () { window.location.reload(); });
        }
    });
})();
