// Support-file upload + delete, shared by the two assignment authoring pages.
//
// One implementation of the flow both pages need: pick files, read each as
// text, POST it as a non-test support entry, and offer a per-row Remove.  The
// two pages had carried near-identical inline copies (the create page's copy
// was the historically stale fork of the pair), differing only in the facts
// this config carries:
//
//   window.initSupportFiles({
//     uploadURL:   () => POST target for {filename, content, tier, isTest}
//     deleteURL:   (name) => DELETE target for one stored support file
//     datasetsURL: () => GET/PUT target for {datasets: [DatasetSpec]}
//                  (a spec is {file, kind, sampleSize, stratumColumn?}; the
//                  response also carries per-file `diagnostics` blocks of
//                  ready-made display strings the rows' estimate chips paint)
//     onChange:    () => run after a successful upload batch or delete
//                  (the edit surface re-renders in place; the create page
//                  reloads its draft)
//     libraryURL:  (op) => POST target for one course-library action, where
//                  op is attach | update | detach | scope | promote
//                  (optional: the create page has no library controls)
//   })
//
// Expects the shared markup ids: #add-support-file-btn,
// #support-file-upload-input, #support-file-upload-status, and per-row
// .js-support-file-delete-btn[data-filename] buttons.
//
// The per-row dataset control (docs/datasets.md Phase 1) lives here too: it is
// the same markup on both pages, so it is the same implementation on both —
// the endpoints are the only difference, and they are already what this config
// carries.  It deliberately does NOT call onChange: a dataset mark changes no
// row and no file, so re-rendering the surface (or reloading the draft) would
// throw away the instructor's place on the page for nothing.
(function () {
    'use strict';

    function readAsText(file) {
        return new Promise(function (resolve, reject) {
            var reader = new FileReader();
            reader.onload = function () { resolve(reader.result); };
            reader.onerror = function () { reject(new Error('Could not read ' + file.name)); };
            reader.readAsText(file);
        });
    }

    // Rows a newly-marked dataset starts at.  The field is editable
    // immediately and the number is not magic — it only keeps the control from
    // being marked-with-no-size, which is a spec the server accepts (it means
    // "the whole file") but which reads as an unfinished edit.
    var DEFAULT_SAMPLE_ROWS = 100;
    // Percent of rows a newly-named blanking column starts at. Low enough that
    // the data is still workable, high enough to be noticed on a small sample.
    var DEFAULT_BLANK_PERCENT = 10;

    // The dataset control listens on the document, so it is bound once per
    // document rather than once per init — the same guard (and the same
    // reason) as suite-table.js's dragover: a caller that re-inits after an
    // in-place write would otherwise stack one more writer per save, and each
    // of them PUTs.
    var boundDatasetControls = false;
    // The first-paint step of the bound control.  A re-init after a workbench
    // swap (#1957) brings server-rendered rows whose estimate chips are empty,
    // so each later init paints them again with this, and binds nothing.
    var resyncDatasetControls = null;

    // The Remove listener is on <body> too, so it has the same guard.  It reads
    // the config of the latest init rather than the first one.
    var boundDeleteClicks = false;
    var deleteConfig = null;

    // ── Per-student dataset marks ───────────────────────────────────────────
    //
    // Each row's checkbox + row-count field describe one DatasetSpec.  The
    // endpoint takes the whole array, so every edit reads the current specs,
    // replaces the entry for this one file, and PUTs the result — which is
    // also what preserves a spec for a file this page isn't showing (one an
    // agent marked on a file that has since been renamed, say).
    function initDatasetControls(config) {
        if (typeof config.datasetsURL !== 'function') return;
        if (boundDatasetControls) {
            if (resyncDatasetControls) resyncDatasetControls();
            return;
        }
        boundDatasetControls = true;

        // Writes are serialized. Each PUT carries the whole array, so two
        // overlapping edits would both be built from the pre-edit state and
        // the first one's change would vanish.
        var queue = Promise.resolve();

        function rows() {
            return Array.prototype.slice.call(
                document.querySelectorAll('tr[data-support-file]'));
        }
        function statusOf(row) { return row.querySelector('.js-dataset-status'); }

        // ── The estimate chips ──────────────────────────────────────────────
        //
        // Two concise numbers per dataset row — student-to-student similarity
        // and drift from the pool — served as ready-made display strings on
        // the same GET/PUT the controls use, so the numbers move with every
        // saved parameter edit and the wording lives in one tested place
        // server-side (DatasetEditHelpers).  A row with no block (not a
        // dataset, or a file the server could not read as text) hides the
        // chips, as does a chip whose number is not measurable.
        function paintChip(chip, text, title) {
            if (!chip) return;
            chip.textContent = text || '';
            chip.title = title || '';
            chip.hidden = !text;
        }

        function renderDiagnostics(reports) {
            var byFile = {};
            (reports || []).forEach(function (report) { byFile[report.file] = report; });
            rows().forEach(function (row) {
                var box = row.querySelector('.js-dataset-estimates');
                if (!box) return;
                var report = byFile[row.getAttribute('data-support-file')];
                box.hidden = !report;
                paintChip(row.querySelector('.js-dataset-similarity'),
                    report && report.similarityDisplay, report && report.similarityTitle);
                paintChip(row.querySelector('.js-dataset-drift'),
                    report && report.driftDisplay, report && report.driftTitle);
            });
        }

        // Paints every row from the server's specs, so a row the edit didn't
        // name still ends up showing what the manifest holds.
        function render(specs) {
            var byFile = {};
            (specs || []).forEach(function (spec) { byFile[spec.file] = spec; });
            rows().forEach(function (row) {
                var toggle = row.querySelector('.js-dataset-toggle');
                var field = row.querySelector('.js-dataset-size-field');
                var size = row.querySelector('.js-dataset-size');
                var stratumField = row.querySelector('.js-dataset-stratum-field');
                var stratum = row.querySelector('.js-dataset-stratum');
                if (!toggle || !field || !size) return;
                var spec = byFile[row.getAttribute('data-support-file')];
                // A partition has no sample, and the panel has no field for
                // its parts: the sample fields stay hidden, the note names the
                // part count and where to edit it, and the toggle is locked so
                // one click cannot end the partition. An attached file's toggle
                // (data-lock="attached") stays locked: detach ends it.
                var partitioned = !!spec && spec.kind === 'partition';
                var sampled = !!spec && !partitioned;
                var attached = !!(toggle.dataset && toggle.dataset.lock === 'attached');
                toggle.disabled = attached || partitioned;
                toggle.checked = !!spec;
                field.hidden = !sampled;
                size.value = (spec && spec.sampleSize != null) ? String(spec.sampleSize) : '';
                if (stratumField) stratumField.hidden = !sampled;
                if (stratum) stratum.value = (spec && spec.stratumColumn) || '';
                var partitionNote = row.querySelector('.js-dataset-partition-note');
                if (partitionNote) partitionNote.hidden = !partitioned;
                var partCount = row.querySelector('.js-dataset-part-count');
                if (partCount && partitioned) partCount.textContent = String(spec.partCount);

                var blankField = row.querySelector('.js-dataset-blank-field');
                if (blankField) blankField.hidden = !sampled;
                var step = editableStep(spec);
                var columns = row.querySelector('.js-dataset-blank-columns');
                var percent = row.querySelector('.js-dataset-blank-percent');
                // A spec whose transforms this panel cannot represent leaves the
                // fields alone AND disabled: painting a partial view of it is how
                // the next edit would save over the part not shown.
                var owned = ownsTransforms(spec);
                if (columns) {
                    columns.disabled = !owned;
                    if (owned) columns.value = step ? (step.columns || []).join(', ') : '';
                }
                if (percent) {
                    percent.disabled = !owned;
                    if (owned) {
                        percent.value = (step && step.rate != null)
                            ? String(Math.round(step.rate * 100)) : '';
                    }
                }
            });
        }

        // The panel edits exactly one shape: no transforms, or a single
        // missingValues step. The model is an ordered list with more kinds to
        // come, so a spec authored through MCP can hold something with no fields
        // here. Saying so explicitly is what lets the panel decline to touch it
        // rather than quietly narrowing it on the next row-count edit.
        function ownsTransforms(spec) {
            var list = (spec && spec.transforms) || [];
            return list.length === 0
                || (list.length === 1 && list[0].kind === 'missingValues');
        }

        function editableStep(spec) {
            if (!ownsTransforms(spec)) return null;
            return ((spec && spec.transforms) || [])[0] || null;
        }

        // The spec a row currently describes. The KIND is derived from whether
        // a column is named, rather than being a separate control: a stratified
        // sample is exactly "a sample, balanced across this column", and a
        // second widget asking the same question in different words is how the
        // two would come to disagree.
        function specFor(row, filename, sampleSize) {
            var stratum = row.querySelector('.js-dataset-stratum');
            var column = stratum ? stratum.value.trim() : '';
            var spec = column
                ? {
                    file: filename,
                    kind: 'stratifiedSample',
                    sampleSize: sampleSize,
                    stratumColumn: column
                }
                : { file: filename, kind: 'rowSample', sampleSize: sampleSize };

            // Only claim `transforms` when the panel's fields are live. When
            // they are disabled the key is omitted entirely, so the merge in
            // `commit` carries the stored steps through untouched.
            var columns = row.querySelector('.js-dataset-blank-columns');
            if (columns && !columns.disabled) {
                spec.transforms = blankStepIn(row);
            }
            return spec;
        }

        // The derivation steps a row describes: one missingValues step when
        // columns are named, and none otherwise. As with the stratum column, the
        // field carries whether the step EXISTS rather than a separate checkbox
        // that could contradict it.
        function blankStepIn(row) {
            var columns = row.querySelector('.js-dataset-blank-columns');
            var percent = row.querySelector('.js-dataset-blank-percent');
            var named = (columns ? columns.value : '')
                .split(',')
                .map(function (name) { return name.trim(); })
                .filter(function (name) { return name.length > 0; });
            if (!named.length) return [];
            var pct = parseInt(percent && percent.value, 10);
            if (!(pct > 0)) pct = DEFAULT_BLANK_PERCENT;
            if (percent) percent.value = String(pct);
            // Authored as a percentage because that is how an instructor says
            // it; stored as the 0 < rate <= 1 fraction the materializer folds to
            // an integer count.
            return [{ kind: 'missingValues', columns: named, rate: pct / 100 }];
        }

        // The row count a row is currently showing, or null when it is blank
        // or not a positive integer.
        function sampleSizeIn(row) {
            var size = row.querySelector('.js-dataset-size');
            var value = parseInt(size && size.value, 10);
            return value > 0 ? value : null;
        }

        function fetchState() {
            return ChickadeeUI.fetchJSON(config.datasetsURL())
                .then(function (body) { return body || {}; });
        }

        // Paints controls and estimates together, from one server response.
        function renderState(body) {
            render((body && body.datasets) || []);
            renderDiagnostics((body && body.diagnostics) || []);
        }

        // Restores the panel to what the server holds — after a failed write
        // so the page never shows a mark that was not saved, and once at init
        // so the estimates have a first paint.
        function resync() {
            return fetchState().then(renderState).catch(function () { /* advisory */ });
        }

        // `spec` null clears the mark for `filename`.
        // The spec to PUT for `filename`: what this control decided, laid over
        // whatever the manifest already held for that file.
        //
        // The panel owns exactly three fields — kind, sampleSize and
        // stratumColumn — and a spec can carry more (transforms, and whatever
        // comes after them). Sending only the fields the panel knows about would
        // drop the rest on an unrelated edit, which is how a stratified spec
        // came within a release of being silently downgraded to a plain sample
        // by someone adjusting a row count. So carry everything forward and
        // overwrite only what was just set.
        function merged(current, filename, spec) {
            var prior = current.filter(function (d) { return d.file === filename; })[0] || {};
            var out = {};
            Object.keys(prior).forEach(function (k) { out[k] = prior[k]; });
            Object.keys(spec).forEach(function (k) { out[k] = spec[k]; });
            // A plain row sample has no stratum column, and a stale one left
            // behind would be refused by the server as a spec that stores a
            // setting its kind ignores. The same holds for a part count on
            // any kind but a partition.
            if (out.kind === 'rowSample') delete out.stratumColumn;
            if (out.kind !== 'partition') delete out.partCount;
            return out;
        }

        function commit(filename, spec, row) {
            queue = queue.then(function () {
                ChickadeeUI.setStatus(statusOf(row), 'Saving…');
                return fetchState().then(function (state) {
                    var current = (state && state.datasets) || [];
                    var next = current.filter(function (d) { return d.file !== filename; });
                    if (spec) next.push(merged(current, filename, spec));
                    return ChickadeeUI.fetchJSON(config.datasetsURL(), {
                        method: 'PUT',
                        body: { datasets: next }
                    });
                }).then(function (body) {
                    renderState(body);
                    ChickadeeUI.setStatus(statusOf(row), spec ? 'Saved' : 'Cleared', 'ok');
                }).catch(function (e) {
                    ChickadeeUI.setStatus(statusOf(row), '');
                    ChickadeeUI.showActionError(
                        'Could not save the dataset setting for "' + filename + '" — ' + e.message, row);
                    return resync();
                });
            });
            return queue;
        }

        document.body.addEventListener('change', function (ev) {
            var target = ev.target;
            if (!target || !target.closest) return;
            var row = target.closest('tr[data-support-file]');
            if (!row) return;
            var filename = row.getAttribute('data-support-file');
            if (!filename) return;
            var size = row.querySelector('.js-dataset-size');
            var field = row.querySelector('.js-dataset-size-field');
            var stratumField = row.querySelector('.js-dataset-stratum-field');
            var blankField = row.querySelector('.js-dataset-blank-field');

            if (target.classList.contains('js-dataset-toggle')) {
                if (!target.checked) {
                    if (field) field.hidden = true;
                    if (stratumField) stratumField.hidden = true;
                    if (blankField) blankField.hidden = true;
                    var estimates = row.querySelector('.js-dataset-estimates');
                    if (estimates) estimates.hidden = true;
                    commit(filename, null, row);
                    return;
                }
                var sampleRows = sampleSizeIn(row) || DEFAULT_SAMPLE_ROWS;
                if (size) size.value = String(sampleRows);
                if (field) {
                    field.hidden = false;
                    if (size && size.focus) { size.focus(); size.select(); }
                }
                if (stratumField) stratumField.hidden = false;
                if (blankField) blankField.hidden = false;
                commit(filename, specFor(row, filename, sampleRows), row);
                return;
            }

            if (target.classList.contains('js-dataset-size')
                || target.classList.contains('js-dataset-stratum')
                || target.classList.contains('js-dataset-blank-columns')
                || target.classList.contains('js-dataset-blank-percent')) {
                var toggle = row.querySelector('.js-dataset-toggle');
                if (toggle && !toggle.checked) return;
                var entered = sampleSizeIn(row);
                if (entered === null) {
                    // Refuse rather than send: the server would reject it too,
                    // and an inline message beside the field is a better answer
                    // than a banner. Resync puts the saved number back.
                    ChickadeeUI.setStatus(statusOf(row), 'Enter 1 or more rows', 'error');
                    resync();
                    return;
                }
                commit(filename, specFor(row, filename, entered), row);
            }
        });

        // First paint of the estimates: the controls are server-rendered, but
        // the numbers come from the same GET the controls sync against.
        resyncDatasetControls = resync;
        resync();
    }

    // ── The course dataset library (docs/datasets-course-library.md §4.5) ──
    //
    // Each control names its file in data-filename, and each action is one
    // POST whose answer is the panel state. The surface then re-renders, as
    // after an upload, because an action can add a file, change a row's
    // source line or remove a row.
    var boundLibraryControls = false;
    // What failed, per action, for the error beside the control.
    var LIBRARY_FAILURES = {
        attach: 'Could not attach the dataset',
        update: 'Could not update the dataset',
        detach: 'Could not detach the dataset',
        scope: 'Could not change the scope',
        promote: 'Could not move the file to the course library'
    };
    var libraryConfig = null;

    // What a library control asks for: the action and its body, or null for
    // an element that is not a library control.
    function libraryRequest(target) {
        if (!target || !target.classList) return null;
        var file = target.getAttribute && target.getAttribute('data-filename');
        if (target.classList.contains('js-library-attach')) {
            var select = document.querySelector('.js-library-attach-select');
            if (!select || !select.value) return null;
            return { op: 'attach', body: { slug: select.value } };
        }
        if (!file) return null;
        if (target.classList.contains('js-library-update')) return { op: 'update', body: { file: file } };
        if (target.classList.contains('js-library-detach')) {
            // The file and its sample stay, so a detach needs no confirm.
            return { op: 'detach', body: { file: file } };
        }
        if (target.classList.contains('js-library-remove')) {
            return {
                op: 'detach', body: { file: file, removeFile: true },
                confirm: 'Remove "' + file + '"? Tests that read it will fail until you re-add it.'
            };
        }
        if (target.classList.contains('js-library-promote')) return { op: 'promote', body: { file: file } };
        if (target.classList.contains('js-library-scope')) {
            return { op: 'scope', body: { file: file, courseScoped: !!target.checked } };
        }
        return null;
    }

    function initLibraryControls(config) {
        if (typeof config.libraryURL !== 'function') return;
        libraryConfig = config;
        if (boundLibraryControls) return;
        boundLibraryControls = true;

        async function send(target) {
            var request = libraryRequest(target);
            if (!request) return;
            var current = libraryConfig;
            // One request per control at a time: a second click while the
            // first is in flight would be refused as already done.
            if (target.disabled) return;
            if (request.confirm && !await ChickadeeUI.confirmAction(request.confirm)) return;
            target.disabled = true;
            try {
                await ChickadeeUI.fetchJSON(current.libraryURL(request.op), {
                    method: 'POST',
                    body: request.body
                });
            } catch (e) {
                // A refused scope change leaves the box as the server holds it.
                if (request.op === 'scope') target.checked = !target.checked;
                ChickadeeUI.showActionError(LIBRARY_FAILURES[request.op] + ' — ' + e.message, target);
                return;
            } finally {
                target.disabled = false;
            }
            current.onChange();
        }

        document.body.addEventListener('click', function (ev) {
            var target = ev.target && ev.target.closest
                && ev.target.closest('.js-library-attach, .js-library-update, .js-library-detach, '
                    + '.js-library-remove, .js-library-promote');
            if (target) send(target);
        });
        document.body.addEventListener('change', function (ev) {
            var target = ev.target;
            if (target && target.classList && target.classList.contains('js-library-scope')) send(target);
        });
    }

    window.initSupportFiles = function (config) {
        var addBtn = document.getElementById('add-support-file-btn');
        var input  = document.getElementById('support-file-upload-input');
        var status = document.getElementById('support-file-upload-status');

        function setStatus(msg, isError) {
            ChickadeeUI.setStatus(status, msg, isError ? 'error' : undefined);
        }

        async function uploadSupportFile(file) {
            var content = await readAsText(file);
            var resp = await fetch(config.uploadURL(), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'x-csrf-token': ChickadeeUI.getCsrfToken()
                },
                credentials: 'same-origin',
                body: JSON.stringify({
                    filename: file.name,
                    content: content,
                    tier: 'support',
                    isTest: false
                })
            });
            if (!resp.ok) {
                var errText = await resp.text();
                throw new Error(resp.status + ': ' + errText);
            }
        }

        if (addBtn && input) {
            addBtn.addEventListener('click', function () { input.click(); });
            input.addEventListener('change', async function () {
                if (!input.files || input.files.length === 0) return;
                setStatus('Uploading…', false);
                try {
                    for (var i = 0; i < input.files.length; i++) {
                        await uploadSupportFile(input.files[i]);
                    }
                    setStatus('Uploaded.', false);
                    config.onChange();
                } catch (e) {
                    setStatus('Upload failed — ' + e.message, true);
                } finally {
                    input.value = '';
                }
            });
        }

        initDatasetControls(config);
        initLibraryControls(config);

        deleteConfig = config;
        if (boundDeleteClicks) return;
        boundDeleteClicks = true;
        document.body.addEventListener('click', async function (ev) {
            var btn = ev.target.closest && ev.target.closest('.js-support-file-delete-btn');
            if (!btn) return;
            var filename = btn.getAttribute('data-filename');
            if (!filename) return;
            var current = deleteConfig;
            if (!await ChickadeeUI.confirmAction('Remove support file "' + filename + '"? Tests that read it will fail until you re-add it.')) return;
            try {
                var resp = await fetch(current.deleteURL(filename), {
                    method: 'DELETE',
                    headers: { 'x-csrf-token': ChickadeeUI.getCsrfToken() },
                    credentials: 'same-origin'
                });
                if (!resp.ok) {
                    var errText = await resp.text();
                    ChickadeeUI.showActionError('Remove failed: ' + resp.status + ' ' + errText, btn);
                    return;
                }
                current.onChange();
            } catch (e) {
                ChickadeeUI.showActionError('Remove failed: ' + e.message, btn);
            }
        });
    };
})();
