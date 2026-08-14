// Support-file upload + delete, shared by the two assignment authoring pages.
//
// One implementation of the flow both pages need: pick files, read each as
// text, POST it as a non-test support entry, and offer a per-row Remove.  The
// two pages had carried near-identical inline copies (the create page's copy
// was the historically stale fork of the pair), differing only in the facts
// this config carries:
//
//   window.initSupportFiles({
//     csrfToken:  value for the x-csrf-token request header
//     uploadURL:  () => POST target for {filename, content, tier, isTest}
//     deleteURL:  (name) => DELETE target for one stored support file
//     onChange:   () => run after a successful upload batch or delete
//                 (the edit surface re-renders in place; the create page
//                 reloads its draft)
//   })
//
// Expects the shared markup ids: #add-support-file-btn,
// #support-file-upload-input, #support-file-upload-status, and per-row
// .js-support-file-delete-btn[data-filename] buttons.
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

        document.body.addEventListener('click', async function (ev) {
            var btn = ev.target.closest && ev.target.closest('.js-support-file-delete-btn');
            if (!btn) return;
            var filename = btn.getAttribute('data-filename');
            if (!filename) return;
            if (!ChickadeeUI.confirmAction('Remove support file "' + filename + '"? Tests that read it will fail until you re-add it.')) return;
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
