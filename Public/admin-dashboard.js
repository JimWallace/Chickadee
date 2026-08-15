// Page wiring for the admin dashboard (admin.leaf): the runner-table load
// summary, the diagnostic cards (headline + sparkline, click cycles the
// 24h/7d/30d window), the Active Users card, and the import-course picker.
// Extracted from the template's inline script block so it is linted and
// testable; the page passes data through server-rendered markup (table rows,
// the pre-rendered 24h activity bars) and the JSON polling endpoints.
(function () {
    'use strict';

    var workersBody = document.getElementById('workers-body');
    if (!workersBody) return;

    var diagJobsProcessed = document.getElementById('diag-jobs-processed');
    var diagMaxLoad = document.getElementById('diag-max-load');
    var diagQueueP95 = document.getElementById('diag-queue-p95');
    var totalRunnerCapacity = 0;
    var totalAssignedJobs = 0;
    var cardsPayload = null;

    function formatDuration(ms) {
        if (ms == null || ms < 0) return '—';
        if (ms < 1000) return ms + 'ms';
        if (ms < 60000) return (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + 's';
        var minutes = Math.floor(ms / 60000);
        var seconds = Math.round((ms % 60000) / 1000);
        return minutes + 'm ' + seconds + 's';
    }

    function setText(el, value) {
        if (el) el.textContent = value;
    }

    function recomputeLoadSummaryFromTable() {
        totalRunnerCapacity = 0;
        totalAssignedJobs = 0;

        Array.from(workersBody.querySelectorAll('tr')).forEach(function (row) {
            totalAssignedJobs += Number(row.getAttribute('data-load') || 0);
            totalRunnerCapacity += Number(row.getAttribute('data-max-jobs') || 0);
        });
    }

    function renderMaxLoadSummary() {
        // Once the sparkline payload has arrived, the card renderer owns the
        // Max Load value; this table-derived sum is only the pre-fetch state.
        if (!diagMaxLoad || cardsPayload) return;
        if (totalRunnerCapacity > 0) {
            setText(diagMaxLoad, String(totalAssignedJobs) + '/' + String(totalRunnerCapacity));
            return;
        }
        setText(diagMaxLoad, '—');
    }

    // ── Diagnostic cards: headline + sparkline, click cycles 24h/7d/30d ──
    var windowNouns = { '24h': 'last 24 hours', '1w': 'last 7 days', '1m': 'last 30 days' };
    var cardWindowIndex = {};
    var sparkCards = [
        {
            key: 'jobsProcessed', name: 'Jobs processed', valueEl: diagJobsProcessed,
            headline: function (data) { return data.headline == null ? '—' : String(data.headline); },
            point: function (v) { return v + (v === 1 ? ' job' : ' jobs'); }
        },
        {
            key: 'load', name: 'Max load', valueEl: diagMaxLoad,
            headline: function (data) {
                if (data.activeJobs == null || data.capacity == null) return '—';
                return String(data.activeJobs) + '/' + String(data.capacity);
            },
            point: function (v) { return v + '% utilization'; }
        },
        {
            key: 'queueWaitP95Ms', name: 'P95 wait time', valueEl: diagQueueP95,
            headline: function (data) { return formatDuration(data.headline); },
            point: formatDuration
        }
    ];

    var renderSpark = ChickadeeSparkline.render;

    function renderSparkCard(config) {
        if (!cardsPayload || !config.cardEl) return;
        var index = cardWindowIndex[config.key] || 0;
        var win = cardsPayload.windows[index % cardsPayload.windows.length];
        var data = win && win[config.key];
        if (!data) return;
        setText(config.valueEl, config.headline(data));
        var chip = config.cardEl.querySelector('.diagnostic-window-chip');
        if (chip) chip.textContent = win.label;
        var spark = config.cardEl.querySelector('.diagnostic-spark');
        if (spark) renderSpark(spark, data.series, win.bucketLabels || [], config.point);
        config.cardEl.setAttribute(
            'aria-label',
            config.name + ', ' + (windowNouns[win.window] || win.label) + '. Press to change time window.');
    }

    function renderAllSparkCards() {
        sparkCards.forEach(renderSparkCard);
    }

    async function refreshCards() {
        try {
            var response = await fetch('/admin/metrics/cards', {
                headers: { 'Accept': 'application/json', 'X-Background-Refresh': '1' },
                cache: 'no-store'
            });
            if (!response.ok) return;
            cardsPayload = await response.json();
            renderAllSparkCards();
        } catch (_) {
            // Keep current card values on transient polling errors.
        }
    }

    sparkCards.forEach(function (config) {
        config.cardEl = document.querySelector('.diagnostic-card[data-card="' + config.key + '"]');
        if (!config.cardEl) return;
        cardWindowIndex[config.key] = 0;
        function cycleWindow() {
            if (!cardsPayload || !cardsPayload.windows.length) return;
            cardWindowIndex[config.key] = (cardWindowIndex[config.key] + 1) % cardsPayload.windows.length;
            renderSparkCard(config);
        }
        config.cardEl.addEventListener('click', cycleWindow);
        config.cardEl.addEventListener('keydown', function (event) {
            if (event.key !== 'Enter' && event.key !== ' ') return;
            event.preventDefault();
            cycleWindow();
        });
    });

    var workersTable = document.getElementById('workers-table');
    if (workersTable) {
        // table-poll.js swaps in server-rendered rows and re-applies the
        // shared behaviours; the Max Load summary is this page's own read of
        // them, so it re-derives from the fresh DOM.
        workersTable.addEventListener('chickadee:table-repaint', function () {
            recomputeLoadSummaryFromTable();
            renderMaxLoadSummary();
        });
    }
    setInterval(function () {
        window.ChickadeeRelativeTime.applyRelativeTimes(document);
    }, 5000);
    setInterval(refreshCards, 60000);

    // Active Users card: sparkline + click-cycle 24h/7d/30d.
    // Reuses the GET /admin/activity endpoint (24h/1w/1m windows). The card's
    // headline is the total active users summed across the buckets; the spark
    // shows the per-bucket trend. The 24h view is server-rendered into the card
    // so there's no fetch-on-load flash; clicking the card cycles the window.
    var activitySpark = document.getElementById('activity-card-spark');
    if (activitySpark) {
        var activityCard = document.querySelector('[data-activity-card]');
        var activityValue = document.getElementById('activity-card-value');
        var activityWindowChip = document.getElementById('activity-card-window');
        var activityWindows = ['24h', '1w', '1m'];
        var activityChipText = { '24h': '24h', '1w': '7d', '1m': '30d' };
        var activityWindow = '24h';

        var renderActivityCard = function (buckets) {
            buckets = Array.isArray(buckets) ? buckets : [];
            // The shared renderer draws the bars (floored so a lone active
            // user shows a visible bar, zero buckets drawn as empty); the
            // data-count / data-label attributes are written back so the DOM
            // stays self-describing for activityBucketsFromDOM().
            renderSpark(
                activitySpark,
                buckets.map(function (b) { return Number(b.count) || 0; }),
                buckets.map(function (b) { return b.label || ''; }),
                function (v) { return v + ' active ' + (v === 1 ? 'user' : 'users'); },
                { floorPct: 20, zeroIsEmpty: true });
            Array.from(activitySpark.children).forEach(function (slot, i) {
                slot.setAttribute('data-count', String(Number(buckets[i] && buckets[i].count) || 0));
                slot.setAttribute('data-label', (buckets[i] && buckets[i].label) || '');
            });
            if (activityValue) activityValue.textContent = String(buckets.reduce(function (s, b) { return s + (Number(b.count) || 0); }, 0));
        };

        var activityBucketsFromDOM = function () {
            return Array.from(activitySpark.querySelectorAll('.spark-slot')).map(function (el) {
                return { count: Number(el.getAttribute('data-count')) || 0, label: el.getAttribute('data-label') || '' };
            });
        };

        var refreshActivityCard = async function () {
            try {
                var res = await fetch('/admin/activity?window=' + encodeURIComponent(activityWindow), {
                    headers: { 'Accept': 'application/json', 'X-Background-Refresh': '1' },
                    cache: 'no-store'
                });
                if (!res.ok) return;
                var data = await res.json();
                renderActivityCard(data.buckets);
            } catch (_) {
                // Keep the current bars on transient polling errors.
            }
        };

        var cycleActivityWindow = function () {
            var idx = activityWindows.indexOf(activityWindow);
            activityWindow = activityWindows[(idx + 1) % activityWindows.length];
            if (activityWindowChip) activityWindowChip.textContent = activityChipText[activityWindow] || activityWindow;
            refreshActivityCard();
        };

        if (activityCard) {
            activityCard.addEventListener('click', cycleActivityWindow);
            activityCard.addEventListener('keydown', function (event) {
                if (event.key === 'Enter' || event.key === ' ') {
                    event.preventDefault();
                    cycleActivityWindow();
                }
            });
        }

        // Size the server-rendered 24h bars immediately (no fetch, no flash),
        // then keep fresh on the runners-table cadence.
        renderActivityCard(activityBucketsFromDOM());
        setInterval(refreshActivityCard, 60000);
    }

    // ── Import course ────────────────────────────────────────────────
    var importFile = document.getElementById('importCourseFile');
    var importForm = document.getElementById('importCourseForm');
    document.getElementById('importCourseBtn').addEventListener('click', function () {
        importFile.click();
    });
    importFile.addEventListener('change', function () {
        if (importFile.files.length > 0) importForm.submit();
    });
})();
