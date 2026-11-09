// @ts-check
// Public/kernel-asset-telemetry.js
//
// How much of a kernel boot came over the network, and the cache warm that
// makes less of it do so (docs/jupyterlite.md, "What a kernel boot
// downloads").
//
// The server renders each vendored kernel's boot files as a list
// (`KernelAssetList`): the binary, its loader, the shared libraries and every
// package tarball, as URLs the kernel itself requests. Three callers read it:
//
//   * notebook.js (source `editor`). The editor's kernel runs in a worker
//     inside the JupyterLite iframe, and resource timing entries stay in the
//     context that made the fetch, so the page cannot read that worker's
//     timings. It asks the HTTP cache instead: before the iframe mounts, a
//     `cache: 'only-if-cached'` request per file (no network, ever) says which
//     files are already cached; once the kernel is idle, the same request for
//     the files that were missing reads their sizes. The iframe reports the
//     JupyterLite shell's own resource timings beside it.
//   * browser-runner.js (source `grading`). A grading worker is Chickadee's
//     own code, so it reads its resource timings directly and hands them over.
//   * kernel-prewarm.js (source `prewarm`). The dashboard fetches the files at
//     idle time, at low priority, once per kernel version per browser.
//
// Each sends one `asset_load` breadcrumb through /api/v1/client-diagnostics;
// `get_browser_diagnostics` folds them into the share of cold loads and the
// bytes served (AssetLoadStats.swift reads the message format below). Sizes
// and timings only: nothing here reads a file a student wrote.
//
// Loading: classic script. Exposes ChickadeeKernelAssets; a CommonJS export
// for the node tests.

(function (root) {
    'use strict';

    /** @typedef {{ env: string, version: string, base: string, files: string[], bytes: number }} KernelAssetList */
    /** @typedef {{ name: string, transferSize?: number, encodedBodySize?: number, decodedBodySize?: number }} TimingEntry */
    /** @typedef {{ netBytes: number, cacheBytes: number, netCount: number, cacheCount: number, unknownCount: number }} Summary */

    // A list from a data attribute, or null when it is absent or not the
    // shape the server renders. Never throws: a page renders either way.
    /** @returns {KernelAssetList | null} */
    function parseList(value) {
        try {
            var list = typeof value === 'string' ? (value ? JSON.parse(value) : null) : value;
            if (!list || typeof list.env !== 'string' || typeof list.base !== 'string'
                || typeof list.version !== 'string' || !Array.isArray(list.files)) {
                return null;
            }
            var files = list.files.filter(function (f) { return typeof f === 'string' && f; });
            if (!files.length) return null;
            return {
                env: list.env, version: list.version, base: list.base, files: files,
                bytes: typeof list.bytes === 'number' ? list.bytes : 0,
            };
        } catch (_) {
            return null;
        }
    }

    /** @returns {KernelAssetList[]} */
    function parseLists(value) {
        try {
            var lists = typeof value === 'string' ? (value ? JSON.parse(value) : []) : value;
            if (!Array.isArray(lists)) return [];
            return lists.map(parseList).filter(function (l) { return l !== null; });
        } catch (_) {
            return [];
        }
    }

    /** @param {KernelAssetList} list */
    function assetURLs(list) {
        return list.files.map(function (f) { return list.base + f; });
    }

    // The path of a URL, absolute or not; null when it does not parse.
    function pathOf(url) {
        try {
            return new URL(String(url), 'https://chickadee.invalid/').pathname;
        } catch (_) {
            return null;
        }
    }

    // One resource timing entry: over the network, from the HTTP cache, or
    // unknown. `transferSize` 0 with a body is a cache hit. A transfer smaller
    // than the body is a revalidation (a 304 carries headers only), which is a
    // cache hit too. An engine that reports no sizes is unknown.
    /** @param {TimingEntry} entry */
    function classify(entry) {
        var t = entry && entry.transferSize;
        var e = entry && entry.encodedBodySize;
        var d = entry && entry.decodedBodySize;
        if (typeof t !== 'number' || typeof e !== 'number' || typeof d !== 'number') {
            return { kind: 'unknown', bytes: 0 };
        }
        var body = e || d;
        if (t === 0) return body > 0 ? { kind: 'cache', bytes: body } : { kind: 'unknown', bytes: 0 };
        if (body > 0 && t < body) return { kind: 'cache', bytes: body };
        return { kind: 'network', bytes: t };
    }

    // Totals over the entries whose path `predicate` accepts.
    /** @returns {Summary} */
    function summarize(entries, predicate) {
        var s = { netBytes: 0, cacheBytes: 0, netCount: 0, cacheCount: 0, unknownCount: 0 };
        (entries || []).forEach(function (entry) {
            var path = pathOf(entry && entry.name);
            if (path === null || (predicate && !predicate(path))) return;
            var c = classify(entry);
            if (c.kind === 'network') { s.netBytes += c.bytes; s.netCount += 1; }
            else if (c.kind === 'cache') { s.cacheBytes += c.bytes; s.cacheCount += 1; }
            else s.unknownCount += 1;
        });
        return s;
    }

    // A kernel boot file: anything under a vendored environment.
    function isKernelPath(path) {
        return path.indexOf('/jupyterlite/xeus/') === 0;
    }

    // The JupyterLite shell: the editor's own bundle, not the kernel, the
    // student's files or the API.
    function isShellPath(path) {
        return path.indexOf('/jupyterlite/') === 0 && !/^\/jupyterlite\/(xeus|files|api)\//.test(path);
    }

    // Plain copies of the fields a summary reads, so entries survive
    // postMessage (a PerformanceResourceTiming does not clone).
    function plainEntries(entries, predicate, max) {
        var out = [];
        var list = entries || [];
        for (var i = 0; i < list.length && out.length < (max || 2000); i++) {
            var entry = list[i];
            var path = pathOf(entry && entry.name);
            if (path === null || (predicate && !predicate(path))) continue;
            out.push({
                name: path,
                transferSize: entry.transferSize,
                encodedBodySize: entry.encodedBodySize,
                decodedBodySize: entry.decodedBodySize,
            });
        }
        return out;
    }

    // The breadcrumb message: `key=value` pairs, skipping absent values.
    function formatMessage(fields) {
        return Object.keys(fields)
            .filter(function (k) { return fields[k] !== undefined && fields[k] !== null && fields[k] !== ''; })
            .map(function (k) { return k + '=' + fields[k]; })
            .join(';')
            .slice(0, 1000);
    }

    // The fields every source shares, from a kernel-file summary.
    function kernelFields(summary) {
        var known = summary.netCount + summary.cacheCount > 0;
        return {
            cold: known ? (summary.netCount > 0 ? 1 : 0) : undefined,
            net_bytes: summary.netBytes,
            cache_bytes: summary.cacheBytes,
            net_n: summary.netCount,
            cache_n: summary.cacheCount,
            unknown_n: summary.unknownCount || undefined,
        };
    }

    // The grading worker's message: its own timings of the kernel files.
    function gradingMessage(entries, bootMs, env) {
        var fields = kernelFields(summarize(entries, isKernelPath));
        fields.boot_ms = typeof bootMs === 'number' ? Math.round(bootMs) : undefined;
        fields.env = env || undefined;
        return formatMessage(fields);
    }

    // ---- the cache probe (editor) ---------------------------------------

    // Whether each URL is in the HTTP cache, without touching the network: a
    // `only-if-cached` request resolves from the cache or fails. Size from the
    // cached response's Content-Length (null when it has none). The body is
    // cancelled, never read.
    async function probeOne(url, fetchImpl) {
        try {
            var res = await fetchImpl(url, {
                cache: 'only-if-cached', mode: 'same-origin', credentials: 'same-origin',
            });
            var cached = !!(res && res.ok);
            var length = res && res.headers && res.headers.get ? Number(res.headers.get('content-length')) : NaN;
            try { if (res && res.body && res.body.cancel) res.body.cancel(); } catch (_) { /* nothing to free */ }
            return { url: url, cached: cached, bytes: cached && length > 0 ? length : null };
        } catch (_) {
            return { url: url, cached: false, bytes: null };
        }
    }

    async function probeCached(urls, fetchImpl) {
        var results = [];
        for (var i = 0; i < urls.length; i += 8) {
            var batch = await Promise.all(urls.slice(i, i + 8).map(function (u) { return probeOne(u, fetchImpl); }));
            results = results.concat(batch);
        }
        return results;
    }

    function sumBytes(results) {
        return results.reduce(function (n, r) { return n + (r.bytes || 0); }, 0);
    }

    // Starts the editor's probe; `finish` composes its message once the kernel
    // is idle. Call `editorProbe` before the iframe loads, so the first probe
    // sees the cache as the kernel will find it.
    //
    // `finish` resolves to the message, or '' when there is nothing to report.
    // A file missing before the boot and cached after it came over the
    // network. A file missing both times was not fetched, or this engine does
    // not honour `only-if-cached`; when nothing at all is cached after a boot,
    // it is the second, and the message says `probe=unsupported` with no
    // `cold`.
    /** @param {KernelAssetList} list */
    function editorProbe(list, fetchImpl) {
        var urls = assetURLs(list);
        var before = probeCached(urls, fetchImpl);
        return {
            before: before,
            finish: async function (options) {
                var first = await before;
                var missing = first.filter(function (r) { return !r.cached; }).map(function (r) { return r.url; });
                var second = missing.length ? await probeCached(missing, fetchImpl) : [];
                var hits = first.filter(function (r) { return r.cached; });
                var fetched = second.filter(function (r) { return r.cached; });
                var fields = {};
                if (!hits.length && !fetched.length) {
                    fields.probe = 'unsupported';
                } else {
                    fields = {
                        cold: fetched.length > 0 ? 1 : 0,
                        net_bytes: sumBytes(fetched),
                        cache_bytes: sumBytes(hits),
                        net_n: fetched.length,
                        cache_n: hits.length,
                        unknown_n: (missing.length - fetched.length) || undefined,
                    };
                }
                var shell = summarize((options && options.shellEntries) || [], isShellPath);
                if (shell.netCount + shell.cacheCount > 0) {
                    fields.shell_net_bytes = shell.netBytes;
                    fields.shell_cache_bytes = shell.cacheBytes;
                }
                var bootMs = options && options.bootMs;
                fields.boot_ms = typeof bootMs === 'number' && isFinite(bootMs) ? Math.round(bootMs) : undefined;
                fields.env = list.env;
                return formatMessage(fields);
            },
        };
    }

    // `elapsed_ms` from a kernel_idle breadcrumb's message, or null.
    function elapsedFrom(message) {
        var m = /(?:^|;)elapsed_ms=(\d+)/.exec(String(message || ''));
        return m ? Number(m[1]) : null;
    }

    // ---- the cache warm (dashboard) ---------------------------------------

    var WARMED_KEY_PREFIX = 'ck-kernel-warm:';
    // A warmed kernel is warmed again after this long. The marker records
    // that the files arrived, not that the browser still has them (Safari
    // evicts readily); a re-warm of cached files costs no download for the
    // immutable tarballs and a 304 for the rest.
    var REWARM_AFTER_MS = 7 * 24 * 3600 * 1000;

    // The marker: "<version>|<epoch ms>". Null when absent or malformed.
    function readMarker(value) {
        var m = /^(.+)\|(\d+)$/.exec(String(value || ''));
        return m ? { version: m[1], at: Number(m[2]) } : null;
    }

    // The lists to warm: none on a data-saving or 2G connection, and none
    // this browser warmed at this version in the last REWARM_AFTER_MS.
    // `storage` may be null (private mode): every list is then warmed, and a
    // cached file costs no download.
    /** @param {KernelAssetList[]} lists */
    function warmPlan(lists, connection, storage, now) {
        try {
            if (connection && (connection.saveData === true
                || connection.effectiveType === 'slow-2g' || connection.effectiveType === '2g')) {
                return [];
            }
        } catch (_) { /* no connection info: warm */ }
        var at = typeof now === 'number' ? now : Date.now();
        return lists.filter(function (list) {
            try {
                var marker = storage ? readMarker(storage.getItem(WARMED_KEY_PREFIX + list.env)) : null;
                return !marker || marker.version !== list.version || at - marker.at >= REWARM_AFTER_MS;
            } catch (_) {
                return true;
            }
        });
    }

    function markWarmed(list, storage, now) {
        try {
            if (storage) {
                storage.setItem(WARMED_KEY_PREFIX + list.env,
                    list.version + '|' + (typeof now === 'number' ? now : Date.now()));
            }
        } catch (_) { /* best-effort */ }
    }

    // Fetches one file into the HTTP cache and discards the bytes. Same URL,
    // method and credentials as the kernel's own request, so the kernel reads
    // this entry. Resolves true on a 2xx.
    async function warmOne(url, fetchImpl) {
        var res = await fetchImpl(url, { credentials: 'same-origin', priority: 'low' });
        if (!res || !res.ok) return false;
        if (res.body && res.body.getReader) {
            var reader = res.body.getReader();
            for (;;) {
                var chunk = await reader.read();
                if (chunk.done) break;
            }
        } else if (res.arrayBuffer) {
            await res.arrayBuffer();
        }
        return true;
    }

    // Warms one list, file by file. Stops at the first failure and leaves the
    // list unmarked, so the next visit tries again. Resolves to whether every
    // file arrived.
    /** @param {KernelAssetList} list */
    async function warmList(list, fetchImpl, storage, now) {
        var urls = assetURLs(list);
        for (var i = 0; i < urls.length; i++) {
            if (!await warmOne(urls[i], fetchImpl)) return false;
        }
        markWarmed(list, storage, now);
        return true;
    }

    // The warm's message, from the page's own timings of this list's files.
    function prewarmMessage(list, entries, warmMs) {
        var wanted = Object.create(null);
        assetURLs(list).forEach(function (u) { wanted[pathOf(u) || u] = true; });
        var fields = kernelFields(summarize(entries, function (p) { return wanted[p] === true; }));
        fields.warm_ms = typeof warmMs === 'number' ? Math.round(warmMs) : undefined;
        fields.env = list.env;
        return formatMessage(fields);
    }

    // ---- sending ----------------------------------------------------------

    function csrfToken() {
        try {
            if (root.ChickadeeUI && root.ChickadeeUI.getCsrfToken) return root.ChickadeeUI.getCsrfToken();
        } catch (_) { /* fall through */ }
        return '';
    }

    function appVersion() {
        try {
            var m = root.document && root.document.querySelector('meta[name="app-version"]');
            return m && m.content ? String(m.content).slice(0, 32) : undefined;
        } catch (_) {
            return undefined;
        }
    }

    // Posts one `asset_load` breadcrumb. Fire-and-forget; never throws. The
    // same shape as `recordSubmitPhase` in browser-runner.js and
    // `postDiagnostic` in notebook-preflight.js; this one exists because the
    // dashboard loads neither.
    function report(source, message, testSetupID) {
        try {
            if (!message) return;
            var body = { kind: 'asset_load', source: String(source).slice(0, 64), message: message };
            if (testSetupID) body.testSetupID = String(testSetupID);
            var version = appVersion();
            if (version) body.appVersion = version;
            root.fetch('/api/v1/client-diagnostics', {
                method: 'POST',
                credentials: 'same-origin',
                keepalive: true,
                headers: { 'content-type': 'application/json', 'x-csrf-token': csrfToken() },
                body: JSON.stringify(body),
            }).catch(function () { /* telemetry is best-effort */ });
        } catch (_) { /* never let telemetry break a page */ }
    }

    var api = {
        parseList: parseList,
        parseLists: parseLists,
        assetURLs: assetURLs,
        classify: classify,
        summarize: summarize,
        isKernelPath: isKernelPath,
        isShellPath: isShellPath,
        plainEntries: plainEntries,
        formatMessage: formatMessage,
        gradingMessage: gradingMessage,
        probeCached: probeCached,
        editorProbe: editorProbe,
        elapsedFrom: elapsedFrom,
        warmPlan: warmPlan,
        warmList: warmList,
        prewarmMessage: prewarmMessage,
        report: report,
        WARMED_KEY_PREFIX: WARMED_KEY_PREFIX,
        REWARM_AFTER_MS: REWARM_AFTER_MS,
    };

    root.ChickadeeKernelAssets = api;
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}(typeof self !== 'undefined' ? self : globalThis));
