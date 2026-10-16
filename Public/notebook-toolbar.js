// Public/notebook-toolbar.js
//
// The notebook editor's one toolbar (notebook views NB2, design frame 18a).
// `NotebookToolbar` renders it. This script:
//
//   - opens the file input a `data-nb-upload` button names (⋯ → Upload);
//   - runs a button's `data-nb-commands` (JupyterLab command ids, in order)
//     through notebook.js's bridge-first command channel
//     (`window.chickadeeEditorCommand`);
//   - follows the Chickadee extension's events from the editor iframe:
//     `ck:kernel` sets the kernel chip, `ck:saved` the save state;
//   - configures the extension for each new editor document: the definition
//     patterns from `#jl-frame[data-definition-patterns]`, and the theme
//     that matches the page (`chickadee:set-theme`), again whenever the
//     page's colour scheme changes.
//
// Messages are accepted from this origin only, with a `ck` field this script
// knows, as notebook.js accepts the kernel diagnostics.

(function (global) {
    'use strict';

    var KERNEL_WORDS = { starting: 'starting', idle: 'idle', busy: 'busy', dead: 'stopped' };
    var SAVE_WORDS = { started: 'Saving…', completed: 'Saved', failed: 'Not saved' };

    /// The chip's word for a ck:kernel status. Pure.
    function kernelWord(status) {
        return KERNEL_WORDS[status] || 'starting';
    }

    /// The save state's text for a ck:saved state, or null to hide it. Pure.
    function saveText(state) {
        return SAVE_WORDS[state] || null;
    }

    /// 'dark' or 'light' for the page: an explicit `data-theme` on the root
    /// wins, as in styles.css; otherwise the system preference. Pure.
    function themeFor(dataTheme, prefersDark) {
        if (dataTheme === 'dark' || dataTheme === 'light') return dataTheme;
        return prefersDark ? 'dark' : 'light';
    }

    /// The command ids in a `data-nb-commands` value. Pure.
    function commandList(value) {
        return String(value || '').split(/\s+/).filter(Boolean);
    }

    var api = { kernelWord: kernelWord, saveText: saveText, themeFor: themeFor, commandList: commandList };

    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var configured = false;

        var run = async function (commands) {
            var execute = window.chickadeeEditorCommand;
            if (typeof execute !== 'function') return false;
            for (var i = 0; i < commands.length; i++) {
                if (!(await execute(commands[i]))) return false;
            }
            return true;
        };

        var darkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
        var currentTheme = function () {
            return themeFor(document.documentElement.getAttribute('data-theme'), !!(darkQuery && darkQuery.matches));
        };
        var sendTheme = function () {
            var execute = window.chickadeeEditorCommand;
            if (typeof execute === 'function') void execute('chickadee:set-theme', { theme: currentTheme() });
        };

        var configure = function () {
            var execute = window.chickadeeEditorCommand;
            var frame = document.getElementById('jl-frame');
            if (typeof execute !== 'function' || !frame) return;
            var patterns = [];
            try {
                patterns = JSON.parse(frame.getAttribute('data-definition-patterns') || '[]');
            } catch (_) { /* no patterns: names are then empty */ }
            configured = true;
            void execute('chickadee:configure', { patterns: patterns });
            sendTheme();
        };

        var setKernel = function (status) {
            var chip = document.getElementById('nb-kernel-chip');
            if (!chip) return;
            chip.hidden = false;
            chip.setAttribute('data-state', status in KERNEL_WORDS ? status : 'starting');
            var word = chip.querySelector('.js-nb-kernel-state');
            if (word) word.textContent = kernelWord(status);
        };

        var setSaved = function (state) {
            var el = document.getElementById('nb-save-state');
            if (!el) return;
            var text = saveText(state);
            el.textContent = text || '';
            el.hidden = !text;
        };

        document.addEventListener('click', function (e) {
            // ⋯ → Upload .ipynb: open the hidden file input it names.
            var upload = e.target && e.target.closest ? e.target.closest('[data-nb-upload]') : null;
            if (upload && upload.closest('.notebook-header')) {
                var menuOfUpload = upload.closest('details');
                if (menuOfUpload) menuOfUpload.removeAttribute('open');
                var input = document.getElementById(upload.getAttribute('data-nb-upload'));
                if (input) input.click();
                return;
            }
            var target = e.target && e.target.closest ? e.target.closest('[data-nb-commands]') : null;
            if (!target || !target.closest('.notebook-header')) return;
            var menu = target.closest('details');
            if (menu) menu.removeAttribute('open');
            void run(commandList(target.getAttribute('data-nb-commands')));
        });

        window.addEventListener('message', function (e) {
            try {
                if (!e || e.origin !== window.location.origin) return;
                var d = e.data;
                if (!d || typeof d.ck !== 'string') return;
                // A new editor document (a first load, a recovery reload or a
                // workbench switch) needs the extension configured again.
                if (d.ck === 'kernel-diag' && d.kind === 'kernel_phase' && d.source === 'boot_start') {
                    configured = false;
                    return;
                }
                if (d.ck === 'ck:kernel') {
                    if (!configured) configure();
                    setKernel(d.status);
                } else if (d.ck === 'ck:saved') {
                    setSaved(d.state);
                }
            } catch (_) { /* the toolbar must never break the page */ }
        });

        if (darkQuery && typeof darkQuery.addEventListener === 'function') {
            darkQuery.addEventListener('change', function () { if (configured) sendTheme(); });
        }

        global.ChickadeeNotebookToolbar = api;
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
