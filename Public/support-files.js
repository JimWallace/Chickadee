// Support-file upload + delete, shared by the two assignment authoring pages.
//
// One implementation of the flow both pages need: pick files, read each as
// text, POST it as a non-test support entry, and offer a per-row Remove.  The
// two pages had carried near-identical inline copies (the create page's copy
// was the historically stale fork of the pair), differing only in the facts
// this config carries:
//
//   window.initSupportFiles({
//     csrfToken:   value for the x-csrf-token request header
//     uploadURL:   () => POST target for {filename, content, tier, isTest}
//     deleteURL:   (name) => DELETE target for one stored support file
//     datasetsURL: () => GET/PUT target for {datasets: [DatasetSpec]}
//                  (a spec is {file, kind, sampleSize, stratumColumn?})
//     onChange:    () => run after a successful upload batch or delete
//                  (the edit surface re-renders in place; the create page
//                  reloads its draft)
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

    // The dataset control listens on the document, so it is bound once per
    // document rather than once per init — the same guard (and the same
    // reason) as suite-table.js's dragover: a caller that re-inits after an
    // in-place write would otherwise stack one more writer per save, and each
    // of them PUTs.
    var boundDatasetControls = false;

    // ── Per-student dataset marks ───────────────────────────────────────────
    //
    // Each row's checkbox + row-count field describe one DatasetSpec.  The
    // endpoint takes the whole array, so every edit reads the current specs,
    // replaces the entry for this one file, and PUTs the result — which is
    // also what preserves a spec for a file this page isn't showing (one an
    // agent marked on a file that has since been renamed, say).
    function initDatasetControls(config, csrfToken) {
        if (typeof config.datasetsURL !== 'function') return;
        if (boundDatasetControls) return;
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
                toggle.checked = !!spec;
                field.hidden = !spec;
                size.value = (spec && spec.sampleSize != null) ? String(spec.sampleSize) : '';
                if (stratumField) stratumField.hidden = !spec;
                if (stratum) stratum.value = (spec && spec.stratumColumn) || '';
            });
        }

        // The spec a row currently describes. The KIND is derived from whether
        // a column is named, rather than being a separate control: a stratified
        // sample is exactly "a sample, balanced across this column", and a
        // second widget asking the same question in different words is how the
        // two would come to disagree.
        function specFor(row, filename, sampleSize) {
            var stratum = row.querySelector('.js-dataset-stratum');
            var column = stratum ? stratum.value.trim() : '';
            if (!column) {
                return { file: filename, kind: 'rowSample', sampleSize: sampleSize };
            }
            return {
                file: filename,
                kind: 'stratifiedSample',
                sampleSize: sampleSize,
                stratumColumn: column
            };
        }

        // The row count a row is currently showing, or null when it is blank
        // or not a positive integer.
        function sampleSizeIn(row) {
            var size = row.querySelector('.js-dataset-size');
            var value = parseInt(size && size.value, 10);
            return value > 0 ? value : null;
        }

        function fetchSpecs() {
            return ChickadeeUI.fetchJSON(config.datasetsURL(), { csrfToken: csrfToken })
                .then(function (body) { return (body && body.datasets) || []; });
        }

        // Restores the controls to what the server holds — used after a failed
        // write so the page never shows a mark that was not saved.
        function resync() {
            return fetchSpecs().then(render).catch(function () { /* advisory */ });
        }

        // `spec` null clears the mark for `filename`.
        function commit(filename, spec, row) {
            queue = queue.then(function () {
                ChickadeeUI.setStatus(statusOf(row), 'Saving…');
                return fetchSpecs().then(function (current) {
                    var next = current.filter(function (d) { return d.file !== filename; });
                    if (spec) next.push(spec);
                    return ChickadeeUI.fetchJSON(config.datasetsURL(), {
                        method: 'PUT',
                        csrfToken: csrfToken,
                        body: { datasets: next }
                    });
                }).then(function (body) {
                    render((body && body.datasets) || []);
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

            if (target.classList.contains('js-dataset-toggle')) {
                if (!target.checked) {
                    if (field) field.hidden = true;
                    if (stratumField) stratumField.hidden = true;
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
                commit(filename, specFor(row, filename, sampleRows), row);
                return;
            }

            if (target.classList.contains('js-dataset-size')
                || target.classList.contains('js-dataset-stratum')) {
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
    }

    window.initSupportFiles = function (config) {
        var csrfToken = config.csrfToken || '';
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
                    'x-csrf-token': csrfToken
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

        initDatasetControls(config, csrfToken);

        document.body.addEventListener('click', async function (ev) {
            var btn = ev.target.closest && ev.target.closest('.js-support-file-delete-btn');
            if (!btn) return;
            var filename = btn.getAttribute('data-filename');
            if (!filename) return;
            if (!await ChickadeeUI.confirmAction('Remove support file "' + filename + '"? Tests that read it will fail until you re-add it.')) return;
            try {
                var resp = await fetch(config.deleteURL(filename), {
                    method: 'DELETE',
                    headers: { 'x-csrf-token': csrfToken },
                    credentials: 'same-origin'
                });
                if (!resp.ok) {
                    var errText = await resp.text();
                    ChickadeeUI.showActionError('Remove failed: ' + resp.status + ' ' + errText, btn);
                    return;
                }
                config.onChange();
            } catch (e) {
                ChickadeeUI.showActionError('Remove failed: ' + e.message, btn);
            }
        });
    };
})();
