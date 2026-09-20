// Public/notebook-preflight-core.js
//
// The decisions behind the student submit page's capability preflight and
// failure handling (notebook-preflight.js): which capabilities are missing,
// what counts as a low-memory device, what a diagnostic record carries, the
// copy each fallback variant shows, and the per-page budget on error reports.
// Nothing here touches the DOM, `navigator` or `fetch`; the wiring probes the
// browser and passes plain values in, so the rules run under node
// (notebook-preflight-core.test.mjs).
(function () {
    'use strict';

    var DIAGNOSTICS_URL = '/api/v1/client-diagnostics';
    var MAX_ERROR_REPORTS = 8;
    var DEVICE_WARNING_DISMISSED_KEY = 'ck_device_warn_dismissed';
    var BROWSER_WARNING_DISMISSED_KEY = 'ck_browser_warn_dismissed';

    /// The capability names the editor needs and the page lacks, in the order
    /// the diagnostic reports them. `env` says which APIs are present.
    function missingCapabilities(env) {
        var failed = [];
        if (!env.webAssembly)  failed.push('WebAssembly');
        if (!env.worker)       failed.push('Worker');
        if (!env.serviceWorker) failed.push('serviceWorker');
        if (!env.indexedDB)    failed.push('indexedDB');
        return failed;
    }

    /// `navigator.deviceMemory` is GB rounded to a power of two, Chromium
    /// only. At most 2 GB is the low-RAM Chromebook and Android population.
    function isLowMemory(deviceMemory) {
        return deviceMemory !== null && deviceMemory > 0 && deviceMemory <= 2;
    }

    /// The preflight verdict. Low memory is a hint, never a failed check.
    function preflightResult(failed, deviceMemory) {
        var dm = (typeof deviceMemory === 'number') ? deviceMemory : null;
        return { ok: failed.length === 0, failed: failed, lowMemory: isLowMemory(dm), deviceMemory: dm };
    }

    /// The copy a fallback panel shows for each non-generic situation. The
    /// generic "Editor didn't load" copy is the template's own text.
    var FALLBACK_COPY = {
        memory: {
            title: 'Your browser ran low on memory',
            text: 'The notebook kernel stopped because your browser hit a memory limit — ' +
                'common on Safari and on phones, tablets, or low-memory computers. ' +
                'Reload to try again, or open this assignment on a laptop or desktop in ' +
                'Chrome or Firefox. You can also submit by uploading your .ipynb file below.'
        },
        slow: {
            title: 'The editor is taking a while to load',
            text: 'The in-browser kernel may not work on older browsers, or on devices with limited ' +
                'memory such as some iPads. If the editor doesn’t finish loading, a laptop or ' +
                'desktop — or a more recent browser — may work better. You can still submit ' +
                'by uploading your notebook (.ipynb) file below.'
        }
    };

    /// The plain-text detail block under a failure: the kind, the user agent,
    /// and the failed checks when there are any.
    function failureDetailsText(info, userAgent) {
        var lines = [
            'Failure: ' + info.kind,
            'User-Agent: ' + (userAgent || '(unknown)')
        ];
        if (info.failedChecks && info.failedChecks.length) {
            lines.push('Failed checks: ' + info.failedChecks.join(', '));
        }
        return lines.join('\n');
    }

    /// Where "reset the notebook editor" sends the student back afterwards:
    /// this assignment, not the dashboard.
    function resetEditorHref(pathname, search) {
        return '/reset-editor?next=' + encodeURIComponent(pathname + search);
    }

    /// The page build's version from the `app-version` meta, capped; '' absent.
    function appVersionFrom(content) {
        return content ? String(content).slice(0, 32) : '';
    }

    /// The JSON body of one diagnostic record. Client-side caps are generous;
    /// the server trims to its own bounds.
    function diagnosticBody(info, extras) {
        var body = { kind: info.kind };
        if (info.failedChecks && info.failedChecks.length) body.failedChecks = info.failedChecks;
        if (extras.setupID) body.testSetupID = extras.setupID;
        if (info.message) body.message = String(info.message).slice(0, 2000);
        if (info.stack)   body.stack   = String(info.stack).slice(0, 8000);
        if (info.source)  body.source  = String(info.source).slice(0, 64);
        if (extras.appVersion) body.appVersion = extras.appVersion;
        return body;
    }

    /// The per-page budget on editor_error reports: capped and de-duplicated
    /// by (source, message), so a tight error loop cannot flood the endpoint.
    function createErrorReportGate(max) {
        var limit = (typeof max === 'number') ? max : MAX_ERROR_REPORTS;
        var seen = {};
        var count = 0;
        return {
            admit: function (info) {
                if (!info || count >= limit) return false;
                var key = (info.source || '') + '|' + (info.message || '');
                if (Object.prototype.hasOwnProperty.call(seen, key)) return false;
                seen[key] = true;
                count += 1;
                return true;
            }
        };
    }

    function deviceWarningEvent(deviceMemory) {
        var dm = (typeof deviceMemory === 'number') ? deviceMemory : null;
        return { kind: 'device_warning', source: 'low_memory', message: 'deviceMemory=' + (dm !== null ? dm : 'unknown') };
    }

    function slowBootEvent(userAgent) {
        return { kind: 'editor_error', source: 'slow_boot_notice', message: 'ua=' + (userAgent || '').slice(0, 200) };
    }

    function browserSupportEvent(userAgent) {
        return { kind: 'browser_support', source: 'below_matrix', message: 'ua=' + (userAgent || '').slice(0, 200) };
    }

    var api = {
        DIAGNOSTICS_URL: DIAGNOSTICS_URL,
        MAX_ERROR_REPORTS: MAX_ERROR_REPORTS,
        DEVICE_WARNING_DISMISSED_KEY: DEVICE_WARNING_DISMISSED_KEY,
        BROWSER_WARNING_DISMISSED_KEY: BROWSER_WARNING_DISMISSED_KEY,
        FALLBACK_COPY: FALLBACK_COPY,
        missingCapabilities: missingCapabilities,
        isLowMemory: isLowMemory,
        preflightResult: preflightResult,
        failureDetailsText: failureDetailsText,
        resetEditorHref: resetEditorHref,
        appVersionFrom: appVersionFrom,
        diagnosticBody: diagnosticBody,
        createErrorReportGate: createErrorReportGate,
        deviceWarningEvent: deviceWarningEvent,
        slowBootEvent: slowBootEvent,
        browserSupportEvent: browserSupportEvent
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeNotebookPreflightCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
